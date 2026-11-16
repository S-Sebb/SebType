package dev.sebb.sebtype.next

import android.inputmethodservice.InputMethodService
import android.text.InputType
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import java.text.BreakIterator

/**
 * The text field, through its InputConnection: commits, the composing text, deletes and the enter key. It
 * keeps the selection it expects after its own edits, so a selection update it didn't cause (the user moved
 * the cursor) can be told apart. The ideas follow pristine AOSP's RichInputConnection (Apache-2.0); the code
 * is SebType's.
 */
class Editor(private val ime: InputMethodService) {
    private val ic: InputConnection? get() = ime.currentInputConnection
    private var info: EditorInfo? = null
    private var kind = FieldKind.of(null)

    /** The selection as the field last reported it, or as it will be after our own edits */
    var selStart = -1
        private set
    var selEnd = -1
        private set
    private var composing = false
    /** Where the composing text starts in the field, from the last update; -1 unknown */
    private var composeStart = -1
    /** Cursor positions our own recent edits led to: their updates can arrive after later edits. */
    private val expected = ArrayDeque<Int>()

    fun start(info: EditorInfo, kind: FieldKind) {
        this.info = info
        this.kind = kind
        selStart = info.initialSelStart
        selEnd = info.initialSelEnd
        composing = false
        composeStart = -1
        expected.clear()
    }

    /** A terminal or other field that takes raw key events rather than text */
    private val raw get() = (info?.inputType ?: 0) and InputType.TYPE_MASK_CLASS == InputType.TYPE_NULL

    fun commit(text: String) {
        if (text.isEmpty()) return
        val ic = ic ?: return
        if (raw && text == "\n") return key(KeyEvent.KEYCODE_ENTER)
        val start = if (composing && composeStart >= 0) composeStart else selStart
        ic.commitText(text, 1)
        composing = false
        if (start >= 0) expect(start + text.length)
    }

    /** Shows [text] as the composing text (日本語's conversion), or removes it when empty. */
    fun compose(text: CharSequence) {
        val ic = ic ?: return
        if (text.isEmpty() && !composing) return
        ic.setComposingText(text, 1)
        composing = text.isNotEmpty()
    }

    /** Leaves the composing text in the field as typed text. */
    fun finishComposing() {
        if (!composing) return
        ic?.finishComposingText()
        composing = false
    }

    /** Backspace: the selection, else the character (a whole emoji or accented letter) before the cursor. */
    fun deleteBefore() {
        val ic = ic ?: return
        if (selEnd > selStart && selStart >= 0) {
            ic.commitText("", 1)
            expect(selStart)
            return
        }
        val before = ic.getTextBeforeCursor(32, 0)
        if (raw || before.isNullOrEmpty()) return key(KeyEvent.KEYCODE_DEL)
        val breaks = BreakIterator.getCharacterInstance()
        breaks.setText(before.toString())
        val last = breaks.preceding(before.length).coerceAtLeast(0)
        val n = before.length - last
        ic.deleteSurroundingText(n, 0)
        if (selStart >= 0) expect(selStart - n)
    }

    /** Mozc's edit around a commit: characters (code points) before and after the cursor. */
    fun delete(before: Int, after: Int) {
        if (before == 0 && after == 0) return
        ic?.deleteSurroundingTextInCodePoints(before, after)
    }

    /** Moves the cursor [by] characters from where it is (Mozc puts it between a pair of brackets). */
    fun moveCursor(by: Int) {
        if (by == 0 || selStart < 0) return
        val at = (selStart + by).coerceAtLeast(0)
        ic?.setSelection(at, at)
        expect(at)
    }

    fun enter() {
        val action = info?.imeOptions?.and(EditorInfo.IME_MASK_ACTION) ?: EditorInfo.IME_ACTION_NONE
        if (kind.enter != FieldKind.Enter.NEWLINE) ic?.performEditorAction(action)
        else commit("\n")
    }

    /** Whether the next letter starts a sentence (or a word, as the field asks): English's automatic Shift. */
    fun capsMode(): Boolean {
        val type = info?.inputType ?: return false
        if (type and InputType.TYPE_MASK_CLASS != InputType.TYPE_CLASS_TEXT) return false
        if (type and (InputType.TYPE_TEXT_FLAG_CAP_SENTENCES or InputType.TYPE_TEXT_FLAG_CAP_WORDS or
                InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS) == 0) return false
        return (ic?.getCursorCapsMode(type) ?: 0) != 0
    }

    private fun key(code: Int) {
        ime.sendDownUpKeyEvents(code)
    }

    private fun expect(at: Int) {
        selStart = at
        selEnd = at
        expected.addLast(at)
        if (expected.size > 8) expected.removeFirst()
    }

    /**
     * The field's selection changed; true when the user moved it (or the app changed the text): away from
     * the composing text, or to a place none of our recent edits put it.
     */
    fun selectionChanged(newStart: Int, newEnd: Int, candidatesStart: Int, candidatesEnd: Int): Boolean {
        val external = if (composing) candidatesStart < 0 || newStart < candidatesStart || newEnd > candidatesEnd
        else !(newStart == newEnd && newStart in expected)
        if (composing) composeStart = candidatesStart
        selStart = newStart
        selEnd = newEnd
        return external
    }

    fun beginBatch() = ic?.beginBatchEdit()
    fun endBatch() = ic?.endBatchEdit()
}
