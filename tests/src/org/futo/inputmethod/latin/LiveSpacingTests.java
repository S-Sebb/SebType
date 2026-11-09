package org.futo.inputmethod.latin;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotNull;

import android.app.Instrumentation;
import android.content.Context;
import android.content.SharedPreferences;
import android.inputmethodservice.InputMethodService;
import android.os.ParcelFileDescriptor;
import android.text.TextUtils;
import android.view.inputmethod.InputConnection;

import androidx.test.platform.app.InstrumentationRegistry;
import androidx.test.runner.AndroidJUnit4;

import org.futo.inputmethod.keyboard.Key;
import org.futo.inputmethod.keyboard.Keyboard;
import org.futo.inputmethod.keyboard.KeyboardSwitcher;
import org.futo.inputmethod.keyboard.MainKeyboardView;
import org.futo.inputmethod.latin.SuggestedWords.SuggestedWordInfo;
import org.futo.inputmethod.latin.settings.Settings;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;

import java.io.FileInputStream;
import java.lang.reflect.Field;
import java.lang.reflect.Method;

/**
 * SebType: spacing tests that tap the live keyboard in an editor, with default settings. FUTO's
 * InputTestsBase builds LatinIME without a real input window, which no longer starts, and keys
 * sent straight to the input logic miss the bug in #39 that real taps show.
 */
@RunWith(AndroidJUnit4.class)
public class LiveSpacingTests {
    private final Instrumentation mInstrumentation = InstrumentationRegistry.getInstrumentation();
    private LatinIMELegacy mIme;
    private InputMethodService mService;

    @Before
    public void setUp() throws Exception {
        final String ime = mInstrumentation.getTargetContext().getPackageName() + "/"
                + LatinIME.class.getName();
        shell("ime enable " + ime);
        shell("ime set " + ime);
        // Wait until the keyboard is typing into a new, empty editor. After the instrumentation
        // restarts SebType's process, the system can take a while to bind the keyboard again, so
        // the editor is reopened until it does.
        for (int i = 0; i < 120 && !(TextUtils.equals("", textInEditor()) && keyboardShown()); i++) {
            if (i % 25 == 0) shell("am start -W --activity-clear-task -n "
                    + "org.futo.inputmethod.latin.tests/" + EditorActivity.class.getName());
            Thread.sleep(200);
        }
        assertEquals("editor ready", "", textInEditor());
        assertEquals("keyboard shown", true, keyboardShown());
        Thread.sleep(2000); // the keyboard slides in and sets its shift state after it shows
    }

    private boolean keyboardShown() {
        final boolean[] shown = new boolean[1];
        mInstrumentation.runOnMainSync(() -> {
            final MainKeyboardView view = KeyboardSwitcher.getInstance().getMainKeyboardView();
            shown[0] = view != null && view.isShown() && view.getKeyboard() != null;
        });
        return shown[0];
    }

    // #39: a "." typed after a space the user pressed stays put, and the file extension after it
    // is neither moved, capitalised nor autocorrected.
    @Test
    public void spaceThenPeriodStaysPut() throws Exception {
        type("open main .py see notebook .ipynb ");
        assertEquals("Open main .py see notebook .ipynb ", textInEditor());
    }

    // #39: after a tapped suggestion, a "." still joins the word.
    @Test
    public void pickedSuggestionThenPeriod() throws Exception {
        type("this");
        mInstrumentation.runOnMainSync(() -> mIme.pickSuggestionManually(new SuggestedWordInfo(
                "This", "", 1, SuggestedWordInfo.KIND_CORRECTION, Dictionary.DICTIONARY_USER_TYPED,
                SuggestedWordInfo.NOT_AN_INDEX, SuggestedWordInfo.NOT_A_CONFIDENCE)));
        Thread.sleep(300);
        type(".");
        assertEquals("This. ", textInEditor());
    }

    // #39: a sentence still ends with ". " and the next word starts with a capital.
    @Test
    public void sentenceThenCapital() throws Exception {
        type("hello. how");
        assertEquals("Hello. How", textInEditor());
    }

    // #39: an install that stored FUTO's default moves to SebType's once; a later choice stays.
    @Test
    public void storedFutoDefaultMigratesOnce() throws Exception {
        final SharedPreferences prefs = mInstrumentation.getTargetContext()
                .getSharedPreferences("sebtype-test-alt-spaces", Context.MODE_PRIVATE);
        prefs.edit().clear().putInt(Settings.PREF_ALT_SPACES_MODE, Settings.SPACES_MODE_ALL).commit();
        final Method upgrade = Settings.class.getDeclaredMethod("upgradeAltSpacesMode",
                SharedPreferences.class);
        upgrade.setAccessible(true);
        upgrade.invoke(null, prefs);
        assertEquals(Settings.SPACES_MODE_SUGGESTIONS, prefs.getInt(Settings.PREF_ALT_SPACES_MODE, -9));
        prefs.edit().putInt(Settings.PREF_ALT_SPACES_MODE, Settings.SPACES_MODE_ALL).commit();
        upgrade.invoke(null, prefs);
        assertEquals(Settings.SPACES_MODE_ALL, prefs.getInt(Settings.PREF_ALT_SPACES_MODE, -9));
        prefs.edit().clear().commit();
    }

    // Taps each key on the keyboard on screen, so input takes the same path as a finger's.
    private void type(final String text) throws Exception {
        for (final int codePoint : text.codePoints().toArray()) {
            final int[] xy = new int[2];
            mInstrumentation.runOnMainSync(() -> {
                final MainKeyboardView view = KeyboardSwitcher.getInstance().getMainKeyboardView();
                final Keyboard keyboard = view.getKeyboard();
                Key key = keyboard.getKey(codePoint);
                if (key == null) key = keyboard.getKey(Character.toUpperCase(codePoint)); // shifted
                assertNotNull("key " + new String(Character.toChars(codePoint)), key);
                view.getLocationOnScreen(xy);
                xy[0] += view.getPaddingLeft() + key.getX() + key.getWidth() / 2;
                xy[1] += view.getPaddingTop() + key.getY() + key.getHeight() / 2;
            });
            shell("input tap " + xy[0] + " " + xy[1]);
            Thread.sleep(250); // let suggestions and the shift state catch up, as between taps
        }
    }

    // Text before the cursor in the editor the keyboard is bound to, or null if none yet.
    private CharSequence textInEditor() {
        final CharSequence[] text = new CharSequence[1];
        mInstrumentation.runOnMainSync(() -> {
            mIme = (LatinIMELegacy) field(KeyboardSwitcher.getInstance(), "mLatinIMELegacy");
            if (mIme == null) return;
            mService = (InputMethodService) field(mIme, "mInputMethodService");
            final InputConnection ic = mService.getCurrentInputConnection();
            if (ic != null) text[0] = ic.getTextBeforeCursor(1000, 0);
        });
        return text[0];
    }

    private static Object field(final Object owner, final String name) {
        try {
            final Field f = owner.getClass().getDeclaredField(name);
            f.setAccessible(true);
            return f.get(owner);
        } catch (ReflectiveOperationException e) {
            throw new RuntimeException(e);
        }
    }

    private void shell(final String command) throws Exception {
        final ParcelFileDescriptor out =
                mInstrumentation.getUiAutomation().executeShellCommand(command);
        assertNotNull(out);
        try (FileInputStream in = new ParcelFileDescriptor.AutoCloseInputStream(out)) {
            while (in.read() != -1) { /* wait until the command finishes */ }
        }
    }
}
