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

import org.futo.inputmethod.event.Event;
import org.futo.inputmethod.keyboard.KeyboardSwitcher;
import org.futo.inputmethod.latin.SuggestedWords.SuggestedWordInfo;
import org.futo.inputmethod.latin.common.Constants;
import org.futo.inputmethod.latin.settings.Settings;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;

import java.io.FileInputStream;
import java.lang.reflect.Field;
import java.lang.reflect.Method;

/**
 * SebType: spacing tests against the live keyboard in an editor, with default settings. FUTO's
 * InputTestsBase builds LatinIME without a real input window, which no longer starts.
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
        for (int i = 0; i < 120 && !TextUtils.equals("", textInEditor()); i++) {
            if (i % 25 == 0) shell("am start -W --activity-clear-task -n "
                    + "org.futo.inputmethod.latin.tests/" + EditorActivity.class.getName());
            Thread.sleep(200);
        }
        assertEquals("editor ready", "", textInEditor());
    }

    // #39: a "." typed after a space the user pressed stays put, and the file extension after it
    // is neither moved, capitalised nor autocorrected.
    @Test
    public void spaceThenPeriodStaysPut() throws Exception {
        final String text = "open main .py see notebook .ipynb ";
        type(text);
        assertEquals(text, textInEditor());
    }

    // #39: after a tapped suggestion, a "." still joins the word.
    @Test
    public void pickedSuggestionThenPeriod() throws Exception {
        type("this");
        mInstrumentation.runOnMainSync(() -> mIme.pickSuggestionManually(new SuggestedWordInfo(
                "this", "", 1, SuggestedWordInfo.KIND_CORRECTION, Dictionary.DICTIONARY_USER_TYPED,
                SuggestedWordInfo.NOT_AN_INDEX, SuggestedWordInfo.NOT_A_CONFIDENCE)));
        Thread.sleep(300);
        type(".");
        assertEquals("this. ", textInEditor());
    }

    // #39: a sentence still ends with ". " and the next word starts with a capital.
    @Test
    public void sentenceThenCapital() throws Exception {
        type("Hello. ");
        assertEquals("Hello. ", textInEditor());
        final Method caps = LatinIMELegacy.class.getDeclaredMethod("getCurrentAutoCapsState");
        caps.setAccessible(true);
        final int[] state = new int[1];
        mInstrumentation.runOnMainSync(() -> {
            try {
                state[0] = (int) caps.invoke(mIme);
            } catch (ReflectiveOperationException e) {
                throw new RuntimeException(e);
            }
        });
        assertEquals("auto-caps after \". \"", true, state[0] != Constants.TextUtils.CAP_MODE_OFF);
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

    private void type(final String text) throws InterruptedException {
        for (final int codePoint : text.codePoints().toArray()) {
            mInstrumentation.runOnMainSync(() -> mIme.onEvent(Event.createSoftwareKeypressEvent(
                    codePoint, Event.NOT_A_KEY_CODE, Constants.NOT_A_COORDINATE,
                    Constants.NOT_A_COORDINATE, false)));
            Thread.sleep(150); // about typing speed; suggestions update in between
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
