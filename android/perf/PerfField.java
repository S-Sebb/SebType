package dev.sebb.sebtype.perffield;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.os.Trace;
import android.text.Editable;
import android.text.InputType;
import android.text.TextWatcher;
import android.view.Gravity;
import android.view.WindowManager;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputConnectionWrapper;
import android.view.inputmethod.InputContentInfo;
import android.widget.EditText;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;

/**
 * A plain text field for android/perf/perf.sh: it opens with the keyboard up, and with the extra
 * "chars" it starts with that much filler text, cursor at the end (the long-field case); the extra
 * "clip" copies that text just after it opens ("clipimage": a small PNG this app serves, #281), and "hidden"
 * keeps the keyboard down. "kind" makes it a password, PIN, visible-password, private, URL or email field, or
 * one that takes pasted images ("image": it then shows "image <type> <bytes>"), or a one-line field with an
 * app's own Enter action ("action": label "Pay", id 42; it then shows "action <id>", #381).
 * It records only the text length, as the Perfetto counter "sebperf_len", never the text.
 */
public class PerfField extends Activity {
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        String kind = getIntent().getStringExtra("kind");
        EditText field = "image".equals(kind) ? new ImageField(this) : new EditText(this);
        field.setGravity(Gravity.TOP | Gravity.START);
        field.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE
                | InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
        // The field kinds android/test/chinese.py types into (#30).
        if ("password".equals(kind)) {
            field.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        } else if ("pin".equals(kind)) {
            field.setInputType(InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_VARIATION_PASSWORD);
        } else if ("visible-password".equals(kind)) {
            field.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD);
        } else if ("private".equals(kind)) {
            field.setImeOptions(EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING);
        } else if ("url".equals(kind)) {
            field.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        } else if ("email".equals(kind)) {
            field.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS);
        } else if ("action".equals(kind)) {
            field.setInputType(InputType.TYPE_CLASS_TEXT);
            field.setImeActionLabel("Pay", 42);
            field.setOnEditorActionListener((v, id, event) -> { v.setText("action " + id); return true; });
        }
        // No blinking cursor: every frame this app draws then comes from a text change.
        field.setCursorVisible(false);
        int chars = getIntent().getIntExtra("chars", 0);
        StringBuilder text = new StringBuilder(chars + 64);
        while (text.length() < chars) text.append("The quick brown fox jumps over the lazy dog. ");
        field.setText(text);
        field.setSelection(field.length());
        Trace.setCounter("sebperf_len", field.length()); // the starting length, so typed = last - first
        field.addTextChangedListener(new TextWatcher() {
            public void beforeTextChanged(CharSequence s, int start, int count, int after) {}
            public void onTextChanged(CharSequence s, int start, int before, int count) {}
            public void afterTextChanged(Editable s) { Trace.setCounter("sebperf_len", s.length()); }
        });
        setContentView(field);
        field.requestFocus();
        // A copy made in this app, for the incognito clipboard checks (#31): once the keyboard has
        // started on this field, so the keyboard judges the copy by this field, not the one before.
        String clip = getIntent().getStringExtra("clip");
        if (clip != null) {
            field.postDelayed(() -> ((ClipboardManager) getSystemService(CLIPBOARD_SERVICE))
                    .setPrimaryClip(ClipData.newPlainText("test", clip)), 1500);
        }
        if (getIntent().hasExtra("clipimage")) {
            File png = new File(getFilesDir(), "clip.png");
            Bitmap b = Bitmap.createBitmap(64, 48, Bitmap.Config.ARGB_8888);
            b.eraseColor(Color.rgb(194, 80, 106));
            try (FileOutputStream out = new FileOutputStream(png)) {
                b.compress(Bitmap.CompressFormat.PNG, 100, out);
            } catch (IOException e) {
                throw new RuntimeException(e);
            }
            field.postDelayed(() -> ((ClipboardManager) getSystemService(CLIPBOARD_SERVICE)).setPrimaryClip(
                    ClipData.newUri(getContentResolver(), "image", Uri.parse("content://" + ImageProvider.AUTHORITY + "/clip.png"))), 1500);
        }
        // Hidden: the keyboard starts on the field but never shows in it (#139).
        int keyboard = getIntent().getBooleanExtra("hidden", false)
                ? WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN
                : WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE;
        getWindow().setSoftInputMode(keyboard | WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
    }

    /** A field that takes a pasted PNG or JPEG, and shows its type and size instead. */
    static class ImageField extends EditText {
        ImageField(Context context) { super(context); }

        @Override
        public InputConnection onCreateInputConnection(EditorInfo info) {
            InputConnection ic = super.onCreateInputConnection(info);
            info.contentMimeTypes = new String[] {"image/png", "image/jpeg"};
            return new InputConnectionWrapper(ic, false) {
                @Override
                public boolean commitContent(InputContentInfo content, int flags, Bundle opts) {
                    if ((flags & INPUT_CONTENT_GRANT_READ_URI_PERMISSION) != 0) content.requestPermission();
                    long n = 0;
                    try (InputStream in = getContext().getContentResolver().openInputStream(content.getContentUri())) {
                        byte[] buffer = new byte[8192];
                        for (int r; (r = in.read(buffer)) > 0; ) n += r;
                    } catch (IOException | SecurityException e) {
                        setText("image unreadable: " + e);
                        return true;
                    }
                    setText("image " + content.getDescription().getMimeType(0) + " " + n);
                    return true;
                }
            };
        }
    }

    /** Serves the PNG "clipimage" copies. */
    public static class ImageProvider extends ContentProvider {
        static final String AUTHORITY = "dev.sebb.sebtype.perffield.image";

        @Override public boolean onCreate() { return true; }
        @Override public String getType(Uri uri) { return "image/png"; }
        @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
            return ParcelFileDescriptor.open(new File(getContext().getFilesDir(), "clip.png"), ParcelFileDescriptor.MODE_READ_ONLY);
        }
        @Override public Cursor query(Uri u, String[] p, String s, String[] a, String o) { return null; }
        @Override public Uri insert(Uri u, ContentValues v) { return null; }
        @Override public int delete(Uri u, String s, String[] a) { return 0; }
        @Override public int update(Uri u, ContentValues v, String s, String[] a) { return 0; }
    }
}
