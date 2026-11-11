package dev.sebb.sebtype.perffield;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.os.Bundle;
import android.os.Trace;
import android.text.Editable;
import android.text.InputType;
import android.text.TextWatcher;
import android.view.Gravity;
import android.view.WindowManager;
import android.view.inputmethod.EditorInfo;
import android.widget.EditText;

/**
 * A plain text field for sebtype/perf.sh: it opens with the keyboard up, and with the extra
 * "chars" it starts with that much filler text, cursor at the end (the long-field case); the extra
 * "clip" copies that text just after it opens. "kind" makes it a password, PIN, visible-password, private, URL or email field.
 * It records only the text length, as the Perfetto counter "sebperf_len", never the text.
 */
public class PerfField extends Activity {
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        EditText field = new EditText(this);
        field.setGravity(Gravity.TOP | Gravity.START);
        field.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE
                | InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
        // The field kinds sebtype/test-chinese.py types into (#30).
        String kind = getIntent().getStringExtra("kind");
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
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE
                | WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
    }
}
