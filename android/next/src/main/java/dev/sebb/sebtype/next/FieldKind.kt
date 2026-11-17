package dev.sebb.sebtype.next

import android.text.InputType
import android.view.inputmethod.EditorInfo
import dev.sebb.sebtype.core.NativeCore

/**
 * What a text field is, as the keyboard treats it (#30, #31):
 *
 *  - password fields: 中文 and 日本語 type plain letters, nothing is learned or suggested, number row on;
 *  - PIN, number, date and phone fields: a keypad;
 *  - private fields (a private browser tab: no personalised learning), URLs and e-mail addresses: suggestions
 *    as usual from what was learned before, but nothing new is learned (Decisions #2, 2026-11-12);
 *  - e-mail addresses get the number row too.
 */
class FieldKind(
    val field: Int,
    val learns: Boolean,
    val pad: String?,
    val numberRow: Boolean,
    val enter: Enter,
    /** English's: plain (no suggestions or corrections, but e-mail domains) in URL and e-mail fields */
    val englishField: Int = field,
) {
    /** What the enter key does and shows */
    enum class Enter { NEWLINE, GO, SEARCH, SEND, NEXT, PREVIOUS, DONE }

    /** Shown as incognito in the bar: the field itself learns nothing. */
    val incognito get() = !learns

    companion object {
        fun of(info: EditorInfo?): FieldKind {
            val type = info?.inputType ?: InputType.TYPE_NULL
            val variation = type and InputType.TYPE_MASK_VARIATION
            val options = info?.imeOptions ?: 0
            val noLearning = options and EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING != 0
            val enter = enter(options)
            return when (type and InputType.TYPE_MASK_CLASS) {
                InputType.TYPE_CLASS_NUMBER -> {
                    val pin = variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
                    FieldKind(if (pin) NativeCore.FIELD_PASSWORD else NativeCore.FIELD_NUMBER, !pin && !noLearning, "numpad", false, enter)
                }
                InputType.TYPE_CLASS_DATETIME -> FieldKind(NativeCore.FIELD_NUMBER, !noLearning, "numpad", false, enter)
                InputType.TYPE_CLASS_PHONE -> FieldKind(NativeCore.FIELD_PHONE, !noLearning, "phone", false, enter)
                InputType.TYPE_CLASS_TEXT -> when (variation) {
                    InputType.TYPE_TEXT_VARIATION_PASSWORD, InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
                    InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD ->
                        FieldKind(NativeCore.FIELD_PASSWORD, false, null, true, enter)
                    InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS, InputType.TYPE_TEXT_VARIATION_WEB_EMAIL_ADDRESS ->
                        FieldKind(NativeCore.FIELD_TEXT, false, null, true, enter, NativeCore.FIELD_PLAIN)
                    InputType.TYPE_TEXT_VARIATION_URI -> FieldKind(NativeCore.FIELD_TEXT, false, null, false, enter, NativeCore.FIELD_PLAIN)
                    // A field that asks for no suggestions (a code or a search box) gets none in English.
                    else -> FieldKind(NativeCore.FIELD_TEXT, !noLearning, null, false, enter,
                        if (type and InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS != 0) NativeCore.FIELD_PLAIN else NativeCore.FIELD_TEXT)
                }
                // A field that takes raw keys (a terminal)
                else -> FieldKind(NativeCore.FIELD_TEXT, !noLearning, null, false, Enter.NEWLINE)
            }
        }

        private fun enter(options: Int): Enter {
            if (options and EditorInfo.IME_FLAG_NO_ENTER_ACTION != 0) return Enter.NEWLINE
            return when (options and EditorInfo.IME_MASK_ACTION) {
                EditorInfo.IME_ACTION_GO -> Enter.GO
                EditorInfo.IME_ACTION_SEARCH -> Enter.SEARCH
                EditorInfo.IME_ACTION_SEND -> Enter.SEND
                EditorInfo.IME_ACTION_NEXT -> Enter.NEXT
                EditorInfo.IME_ACTION_PREVIOUS -> Enter.PREVIOUS
                EditorInfo.IME_ACTION_DONE -> Enter.DONE
                else -> Enter.NEWLINE
            }
        }
    }
}
