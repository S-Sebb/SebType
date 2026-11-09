package org.futo.inputmethod.latin;

import android.app.Activity;
import android.os.Bundle;
import android.text.InputType;
import android.widget.EditText;

/** SebType: a plain text field for {@link LiveSpacingTests} to type into with the real keyboard. */
public class EditorActivity extends Activity {
    @Override
    protected void onCreate(final Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        final EditText editText = new EditText(this);
        editText.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_AUTO_CORRECT
                | InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
        setContentView(editText);
        editText.requestFocus();
    }
}
