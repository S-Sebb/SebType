package dev.sebb.sebtype.next

import android.inputmethodservice.InputMethodService
import android.text.InputType
import android.os.Build
import android.os.SystemClock
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.ExtractedTextRequest
import android.view.inputmethod.InputConnection
import java.text.BreakIterator

/**
 * The text field, through its InputConnection: commits, the composing text, deletes and the enter key. It
 * keeps the selection it expects after its own edits, so a selection update it didn't cause (the user moved
 * the cursor) can be told apart. The ideas follow pristine AOSP's RichInputConnection (Apache-2.0); the code
 * is SebType's.
 */
class Editor(private val ime: InputMethodService?, private val target: InputConnection? = null) {
    private companion object {
        /** Delete's swipe looks this far back for words */
        const val MAX_SWIPE = 2000
    }

    // [target]: a search in a panel takes the typing instead of the field (#281).
    private val ic: InputConnection? get() = target ?: ime?.currentInputConnection
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
    /** Selections our own recent edits led to: their updates can arrive after later edits. */
    private val expected = ArrayDeque<Pair<Int, Int>>()
    /** The field's text that [composeRegion] made the composing text, until it changes */
    private var regionText: String? = null
    /** Where the user put the cursor inside the composing text at the last update, from its start; -1: not there */
    var movedInside = -1
        private set
    /** Counts the field's changes that weren't ours (a cursor the user moved, the app's own edit) */
    private var revision = 0

    /**
     * The field's text around the cursor (English's context) as it is now, and where the field has the cursor,
     * read with the text: -1 when that isn't where we have it, or the field can't say.
     */
    inner class Around(val before: String, val after: String, selection: Boolean, val at: Int) {
        val revision = this@Editor.revision
        /** Whether a word may be reopened from this read: one is placed by our cursor, so it must be the field's (#280) */
        val reopen = !selection && at >= 0

        /** The text from [b] code points before the cursor to [a] after it, as read then */
        fun text(b: Int, a: Int): String = before.substring(before.offsetByCodePoints(before.length, -minOf(b, before.codePointCount(0, before.length)))) +
            after.substring(0, after.offsetByCodePoints(0, minOf(a, after.codePointCount(0, after.length))))
    }
    fun around(): Around {
        val s = snapshot(1000, 64)
        return if (s != null && s.start == selStart && s.end == selEnd) Around(s.before, s.after, s.start != s.end, s.start)
        else Around(s?.before ?: textBefore(), s?.after ?: textAfter(), selEnd != selStart, -1)
    }

    /** Whether the field is still as [around] read it: no change since that wasn't ours, the cursor and text the same. */
    fun unchanged(around: Around) =
        around.revision == revision && around().let { it.at == around.at && it.before == around.before && it.after == around.after }

    /** The field's text around the cursor and where the selection is in the field, read at once */
    private class Snapshot(val before: String, val after: String, val start: Int, val end: Int)

    /**
     * Up to [before] and [after] characters around the selection, with where it is, in one read: a cursor read
     * apart from the text, or our own idea of it, can be older than the text (#280). Null when the field can't.
     */
    private fun snapshot(before: Int, after: Int): Snapshot? {
        val ic = ic ?: return null
        if (Build.VERSION.SDK_INT >= 31) {
            val s = ic.getSurroundingText(before, after, 0)
            if (s != null && s.offset >= 0) {
                val text = s.text.toString()
                return Snapshot(text.substring(0, s.selectionStart), text.substring(s.selectionEnd), s.offset + s.selectionStart, s.offset + s.selectionEnd)
            }
        }
        val e = ic.getExtractedText(ExtractedTextRequest(), 0) ?: return null
        val text = e.text?.toString() ?: return null
        val start = minOf(e.selectionStart, e.selectionEnd)
        val end = maxOf(e.selectionStart, e.selectionEnd)
        if (e.startOffset < 0 || start < 0 || end > text.length) return null
        return Snapshot(text.substring(maxOf(0, start - before), start), text.substring(end, minOf(text.length, end + after)), e.startOffset + start, e.startOffset + end)
    }

    fun start(info: EditorInfo, kind: FieldKind) {
        this.info = info
        this.kind = kind
        selStart = info.initialSelStart
        selEnd = info.initialSelEnd
        composing = false
        composeStart = -1
        regionText = null
        expected.clear()
        revision++
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
        regionText = null
        if (start >= 0) expect(start + text.length)
    }

    /** Shows [text] as the composing text (日本語's conversion), or removes it when empty. */
    fun compose(text: CharSequence) {
        val ic = ic ?: return
        if (text.isEmpty() && !composing) return
        // The field's own text, marked as it is: the cursor stays where it is in it
        if (text.toString() == regionText.also { regionText = null }) return
        if (!composing) composeStart = selStart // a new composing text starts at the cursor
        ic.setComposingText(text, 1)
        composing = text.isNotEmpty()
        if (composeStart >= 0) expect(composeStart + text.length)
    }

    /** Leaves the composing text in the field as typed text. */
    fun finishComposing() {
        if (!composing) return
        ic?.finishComposingText()
        composing = false
        regionText = null
        if (selStart >= 0) expect(selStart)
    }

    /**
     * Makes the field's text from [before] characters (code points) before the cursor to [after] after it the
     * composing text, as it is (English reopening a word); with neither, the composing text ends where it is.
     * False, and nothing marked, when that text isn't [want] (a reopen read before the field changed).
     */
    fun composeRegion(before: Int, after: Int, want: String? = null): Boolean {
        if (before == 0 && after == 0) return true.also { finishComposing() }
        val ic = ic ?: return false
        // The region is placed by our cursor, so it must be the field's, read with the text (#280)
        val s = snapshot(2 * before, 2 * after)?.takeIf { it.start == selStart && it.end == selStart } ?: return false
        val textBefore = s.before
        val textAfter = s.after
        val b = textBefore.length - textBefore.offsetByCodePoints(textBefore.length, -minOf(before, textBefore.codePointCount(0, textBefore.length)))
        val a = textAfter.offsetByCodePoints(0, minOf(after, textAfter.codePointCount(0, textAfter.length)))
        val text = textBefore.takeLast(b) + textAfter.take(a)
        if (want != null && text != want) return false
        ic.setComposingRegion(selStart - b, selStart + a)
        composing = true
        composeStart = selStart - b
        regionText = text
        expect(selStart)
        return true
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

    /** An engine's edit around a commit: characters (code points) before and after the cursor. */
    fun delete(before: Int, after: Int) {
        if (before == 0 && after == 0) return
        val ic = ic ?: return
        // The cursor moves back by the UTF-16 length of what goes.
        val text = ic.getTextBeforeCursor(2 * before, 0) ?: ""
        val gone = text.length - Character.offsetByCodePoints(text, text.length, -minOf(before, Character.codePointCount(text, 0, text.length)))
        ic.deleteSurroundingTextInCodePoints(before, after)
        if (selStart >= 0) expect(selStart - gone)
    }

    /** The field's text before the cursor (up to [max] characters): English's context. */
    fun textBefore(max: Int = 1000): String = ic?.getTextBeforeCursor(max, 0)?.toString().orEmpty()

    /** The start of the field's text after the cursor: the rest of a word English reopens. */
    fun textAfter(max: Int = 64): String = ic?.getTextAfterCursor(max, 0)?.toString().orEmpty()

    /** Moves the cursor [by] characters from where it is (Mozc puts it between a pair of brackets). */
    fun moveCursor(by: Int) {
        if (by == 0) return
        // From where the field has the cursor: ours can be older (#280)
        val s = snapshot(0, 0) ?: return arrows(by)
        moveTo((s.start + by).coerceAtLeast(0))
    }

    /** Moves the cursor [by] characters (whole code points), as far as the text goes: the space bar's swipe. */
    fun moveBy(by: Int) {
        if (by == 0) return
        val s = snapshot(maxOf(0, -2 * by), maxOf(0, 2 * by)) ?: return arrows(by)
        moveTo(if (by < 0) s.start - (s.before.length - s.before.offsetByCodePoints(s.before.length, -minOf(-by, s.before.codePointCount(0, s.before.length))))
            else s.end + s.after.offsetByCodePoints(0, minOf(by, s.after.codePointCount(0, s.after.length))))
    }

    private fun moveTo(at: Int) {
        ic?.setSelection(at, at)
        expect(at)
    }

    /** A field that can't say where its cursor is: the arrow keys move it from wherever it is */
    private fun arrows(by: Int) = repeat(kotlin.math.abs(by)) { key(if (by < 0) KeyEvent.KEYCODE_DPAD_LEFT else KeyEvent.KEYCODE_DPAD_RIGHT) }

    /** Delete's swipe: the text before the cursor where it started, and where that was (-1: the field can't say) */
    private var swipeText: String? = null
    private var swipeEnd = -1

    /** Delete's swipe: selects [words] words before the cursor (none: back to the cursor), deleted when [done]. */
    fun selectWordsBefore(words: Int, done: Boolean) {
        val ic = ic ?: return
        // From where the field has the cursor, read with the text: ours can be older (#280)
        val text = swipeText ?: (snapshot(MAX_SWIPE, 0)?.also { swipeEnd = it.start }?.before ?: textBefore(MAX_SWIPE)).also { swipeText = it }
        val end = swipeEnd
        val n = text.length - wordsStart(text, words)
        if (end >= 0) {
            ic.setSelection(end - n, end)
            expect(end - n, end)
        }
        if (!done) return
        swipeText = null
        swipeEnd = -1
        if (n == 0) return
        if (end >= 0) {
            ic.commitText("", 1)
            expect(end - n)
        } else {
            // Nothing could be selected: the words go from before the cursor
            ic.deleteSurroundingText(n, 0)
        }
    }

    /**
     * Where [words] words before the end of [text] start, with the spaces after each. Words are the
     * system's word breaks, as today's delete does: Chinese and Japanese, written without spaces, go a word
     * (or a punctuation mark) at a time rather than a sentence.
     */
    private fun wordsStart(text: String, words: Int): Int {
        val breaks = BreakIterator.getWordInstance()
        breaks.setText(text)
        var i = text.length
        repeat(words) {
            while (i > 0 && text[i - 1].isWhitespace()) i--
            if (i > 0) i = breaks.preceding(i).coerceAtLeast(0)
        }
        return i
    }

    fun enter() {
        val action = info?.imeOptions?.and(EditorInfo.IME_MASK_ACTION) ?: EditorInfo.IME_ACTION_NONE
        if (kind.enter != FieldKind.Enter.NEWLINE) ic?.performEditorAction(action)
        else commit("\n")
    }

    /** Whether the next letter starts a sentence (or a word, as the field asks): English's automatic Shift. */
    fun capsMode(): Boolean = capsFlags != 0 && (ic?.getCursorCapsMode(info!!.inputType) ?: 0) != 0

    /** The capitals the field asks for (TextUtils.getCapsMode's modes), 0 for none */
    val capsFlags: Int get() {
        val type = info?.inputType ?: return 0
        if (type and InputType.TYPE_MASK_CLASS != InputType.TYPE_CLASS_TEXT) return 0
        return type and (InputType.TYPE_TEXT_FLAG_CAP_SENTENCES or InputType.TYPE_TEXT_FLAG_CAP_WORDS or
            InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS)
    }

    private fun key(code: Int) {
        if (target == null) ime?.sendDownUpKeyEvents(code)
    }

    /** Undo (Ctrl+Z) and redo (Ctrl+Shift+Z): the field's own, as a hardware keyboard sends them */
    fun undo(redo: Boolean) {
        val meta = KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON or (if (redo) KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_LEFT_ON else 0)
        val now = SystemClock.uptimeMillis()
        ic?.sendKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_Z, 0, meta))
        ic?.sendKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_Z, 0, meta))
    }

    /** Select all, cut, copy or paste ([android.R.id]'s), as the field's own menu does them */
    fun menuAction(id: Int) = ic?.performContextMenuAction(id)

    private fun expect(at: Int) = expect(at, at)

    private fun expect(start: Int, end: Int) {
        selStart = start
        selEnd = end
        expected.addLast(start to end)
        if (expected.size > 64) expected.removeFirst()
    }

    /**
     * The field's selection changed; true when the user moved it (or the app changed the text): out of the
     * composing text, or to a place none of our recent edits put it. Updates come late, in order: one for
     * the last letter of a word can arrive after the word's commit, while the next word already composes.
     */
    fun selectionChanged(newStart: Int, newEnd: Int, candidatesStart: Int, candidatesEnd: Int): Boolean {
        val out = candidatesStart >= 0 && (newStart < candidatesStart || newEnd > candidatesEnd)
        val ours = if (!out) expected.indexOf(newStart to newEnd) else -1
        if (ours >= 0) {
            repeat(ours) { expected.removeFirst() } // the edits before it were reported already
            movedInside = -1
            return false
        }
        // Not ours: the edits still to be reported were placed by the cursor as we had it, so where they leave
        // it can't be told any more; one of those places may be where the user goes next (#280).
        val quiet = expected.isEmpty()
        expected.clear()
        // At the composing text's end is where our own typing leaves it (a field that gave no cursor at the start)
        movedInside = if (!out && composing && candidatesStart >= 0 && newStart == newEnd && quiet &&
            newStart != candidatesEnd) newStart - candidatesStart else -1
        selStart = newStart
        selEnd = newEnd
        if (composing && candidatesStart >= 0) composeStart = candidatesStart
        // A field that gave no cursor at the start: our composing text is where it says.
        val external = out || !(composing && candidatesStart >= 0 && quiet)
        if (external || movedInside >= 0) revision++
        return external
    }

    fun beginBatch() = ic?.beginBatchEdit()
    fun endBatch() = ic?.endBatchEdit()
}
