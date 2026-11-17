package dev.sebb.sebtype.next

import android.inputmethodservice.InputMethodService
import android.text.InputType
import android.text.TextUtils
import android.os.Build
import android.os.SystemClock
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.ExtractedTextRequest
import android.view.inputmethod.InputConnection
import dev.sebb.sebtype.core.NativeState
import java.text.BreakIterator

/**
 * The text field, through its InputConnection: commits, the composing text, deletes and the enter key. It
 * keeps the selection it expects after its own edits, so a selection update it didn't cause (the user moved
 * the cursor) can be told apart, and the text it expects around it, so English's edits go in only where the
 * field still is as the engine knows it (#280). The ideas follow pristine AOSP's RichInputConnection
 * (Apache-2.0); the code is SebType's.
 */
class Editor(private val ime: InputMethodService?, private val target: InputConnection? = null) {
    private companion object {
        /** Delete's swipe looks this far back for words */
        const val MAX_SWIPE = 2000
        /** How much of the text either side of the selection [write] checks, besides the composing text */
        const val CHECK = 64
    }

    // [target]: a search in a panel takes the typing instead of the field (#281).
    private val ic: InputConnection? get() = target ?: ime?.currentInputConnection
    private var info: EditorInfo? = null
    private var kind = FieldKind.of(null)

    /**
     * English (#280): [write] checks the field before each edit, and an update whose composing text isn't the
     * one our edits left counts as the field's own change.
     */
    var checked = false

    /** The selection as the field last reported it, or as it will be after our own edits */
    var selStart = -1
        private set
    var selEnd = -1
        private set
    private var composing = false
    /** Where the composing text starts in the field, from the last update; -1 unknown */
    private var composeStart = -1
    /** The composing text's length in the field */
    private var composeLength = 0
    /** Our recent edits' updates, still to come: the selection and the composing text they leave (-1, -1: none) */
    private val expected = ArrayDeque<List<Int>>()
    /** The field's text that [composeRegion] made the composing text, until it changes */
    private var regionText: String? = null
    /** Where the user put the cursor inside the composing text at the last update, from its start; -1: not there */
    var movedInside = -1
        private set

    /**
     * The field as we expect it: the text around the selection as last read, with each of our own edits since
     * done to it as the field does them. [text]'s [start] to [end] is the selection, [region] the composing
     * text, and [offset] where [text] starts in the field (-1: the field can't say).
     */
    private class Model(var text: String, var start: Int, var end: Int, val offset: Int) {
        var region: IntRange? = null

        /** commitText's and setComposingText's edit: the composing text, else the selection, replaced */
        fun replace(with: String, compose: Boolean) {
            val r = region ?: (start until end)
            text = text.substring(0, r.first) + with + text.substring(r.last + 1)
            start = r.first + with.length
            end = start
            region = if (compose && with.isNotEmpty()) r.first until start else null
        }

        /** deleteSurroundingText's edit, [b] and [a] characters either side of the selection: false when it reaches past what we know */
        fun delete(b: Int, a: Int): Boolean {
            if (region != null || b > start || end + a > text.length) return false
            text = text.substring(0, start - b) + text.substring(start, end) + text.substring(end + a)
            start -= b
            end -= b
            return true
        }
    }
    private var model: Model? = null
    /** The field gave nothing when read: what is in it, and where, is unknown */
    private var blind = false
    /** The field says where its text starts in getSurroundingText (Android 12+): [check] reads that */
    private var surrounds = false

    /** [model], or nothing known when [edit] can't say how the field changed */
    private inline fun model(edit: Model.() -> Boolean) {
        if (model?.edit() == false) model = null
    }

    /** The field's text around the cursor (English's context) as it is now, and whether a word may be reopened in it */
    class Around(val before: String, val after: String, val reopen: Boolean)

    /**
     * Reads the field's text around the cursor: where the field says its cursor is, read with the text, becomes
     * ours. A word may be reopened only where the field says so (#280): one is placed by the cursor. A field
     * that gives nothing is [blind].
     */
    fun around(): Around {
        blind = false
        val s = read(1000, 64)
        if (s != null) return Around(s.before, s.after, s.start == s.end)
        val ic = ic
        val before = ic?.getTextBeforeCursor(1000, 0)?.toString()
        val after = ic?.getTextAfterCursor(64, 0)?.toString()
        val selected = if (selEnd > selStart) ic?.getSelectedText(0)?.toString() else ""
        if (before == null || after == null || selected == null) {
            blind = true
            model = null
            return Around("", "", false)
        }
        model = Model(before + selected + after, before.length, before.length + selected.length, -1)
        return Around(before, after, false)
    }

    /** The field's text around the selection and where the selection is in the field, read at once */
    private class Snapshot(val before: String, val selected: String, val after: String, val start: Int, val end: Int)

    /**
     * Up to [before] and [after] characters around the selection, with where it is, in one read: a cursor read
     * apart from the text, or our own idea of it, can be older than the text (#280). Null when the field can't.
     */
    private fun snapshot(before: Int, after: Int): Snapshot? = surroundingText(before, after) ?: extracted(before, after)

    /** getSurroundingText, from a field that says where its text starts */
    private fun surroundingText(before: Int, after: Int): Snapshot? {
        if (Build.VERSION.SDK_INT < 31) return null
        val s = ic?.getSurroundingText(before, after, 0) ?: return null
        return if (s.offset >= 0) snapshot(s.text, s.selectionStart, s.selectionEnd, s.offset, before, after) else null
    }

    /** getExtractedText: the whole text */
    private fun extracted(before: Int, after: Int): Snapshot? {
        val e = ic?.getExtractedText(ExtractedTextRequest(), 0) ?: return null
        // A part of the text (one that changed) doesn't say where the selection is in the rest
        if (e.partialStartOffset != -1) return null
        return snapshot(e.text, e.selectionStart, e.selectionEnd, e.startOffset, before, after)
    }

    /** [text], which starts at [offset] in the field, with the selection from [a] to [b] in it */
    private fun snapshot(text: CharSequence?, a: Int, b: Int, offset: Int, before: Int, after: Int): Snapshot? {
        val t = text?.toString() ?: return null
        val start = minOf(a, b)
        val end = maxOf(a, b)
        if (offset < 0 || start < 0 || end > t.length) return null
        return Snapshot(t.substring(maxOf(0, start - before), start), t.substring(start, end), t.substring(end, minOf(t.length, end + after)), offset + start, offset + end)
    }

    /** [snapshot], which becomes what we expect of the field: the selection and the text */
    private fun read(before: Int, after: Int): Snapshot? {
        val surrounding = surroundingText(before, after)
        surrounds = surrounding != null
        val s = surrounding ?: extracted(before, after) ?: return null
        selStart = s.start
        selEnd = s.end
        model = Model(s.before + s.selected + s.after, s.before.length, s.before.length + s.selected.length, s.start - s.before.length)
        return s
    }

    /** What [check] found */
    private enum class Check { SAME, CHANGED, UNKNOWN }

    /** Whether the last [check] found the field's cursor where we have it: an edit may be placed by it */
    private var placed = false

    /**
     * Whether the field is as we expect it ([model]): the text either side of the selection, all the composing
     * text (setComposingText replaces it), and where the selection is when the field says. One read: with
     * getSurroundingText where the field says where its text starts, else the text before and after the cursor.
     */
    private fun check(): Check {
        placed = false
        if (blind) return Check.UNKNOWN
        val m = model ?: return Check.CHANGED
        val r = m.region
        val b = maxOf(minOf(CHECK, m.start), if (r != null) m.start - r.first else 0)
        val a = maxOf(minOf(CHECK, m.text.length - m.end), if (r != null) r.last + 1 - m.end else 0)
        if (b > m.start || m.end + a > m.text.length) return Check.CHANGED
        val before = m.text.substring(m.start - b, m.start)
        val selected = m.text.substring(m.start, m.end)
        val after = m.text.substring(m.end, m.end + a)
        if (surrounds) {
            val s = surroundingText(b, a) ?: return Check.UNKNOWN
            placed = s.start == selStart && s.end == selEnd && (m.offset < 0 || s.start == m.offset + m.start)
            return if (placed && s.before == before && s.selected == selected && s.after == after) Check.SAME else Check.CHANGED
        }
        val ic = ic ?: return Check.UNKNOWN
        val fieldBefore = ic.getTextBeforeCursor(b, 0)?.toString() ?: return Check.UNKNOWN
        val fieldAfter = ic.getTextAfterCursor(a, 0)?.toString() ?: return Check.UNKNOWN
        // A selection where none is expected shows in the text after the cursor
        val fieldSelected = if (selected.isEmpty()) "" else ic.getSelectedText(0)?.toString() ?: return Check.UNKNOWN
        return if (fieldBefore == before && fieldSelected == selected && fieldAfter == after) Check.SAME else Check.CHANGED
    }

    /**
     * The engine's edit [st] into the field, then [composition] as the composing text (null: as it is) and
     * [then], in one batch. English's edits of a range ([checked]: a word reopened, the text an undone correction
     * deletes) go in only where the field is as our edits left it ([check]) and that is known. False, with what
     * was composing left in the field as it is, when they can't: the engine must read the field again.
     */
    fun write(st: NativeState, composition: CharSequence?, then: (() -> Unit)? = null): Boolean {
        beginBatch()
        try {
            val range = st.recompose || st.deleteBefore > 0 || st.deleteAfter > 0
            // Typing (a letter, a space, punctuation, a suggestion picked) goes in by the composing text and the
            // cursor and relies on the field's updates, as today's app does: a read before it would delay every
            // key. Taking the composing text away with nothing committed in its place is checked: it would erase
            // what is there.
            val edits = range || st.commitCursor != 0 || st.commit.isEmpty() && composition?.isEmpty() == true && composing
            val check = if (checked && edits) check() else Check.SAME
            if (check == Check.CHANGED || check == Check.UNKNOWN && range || st.recompose && !composeRegion(st.composeBefore, st.composeAfter)) {
                finishComposing()
                return false
            }
            if (st.deleteBefore > 0 || st.deleteAfter > 0) delete(st.deleteBefore, st.deleteAfter, known = checked)
            if (st.commit.isNotEmpty()) commit(st.commit)
            if (st.commitCursor != 0) moveCursor(st.commitCursor)
            if (composition != null) compose(composition)
            then?.invoke()
            return true
        } finally {
            placed = false
            endBatch()
        }
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
        model = null
        blind = false
    }

    /** A terminal or other field that takes raw key events rather than text */
    private val raw get() = (info?.inputType ?: 0) and InputType.TYPE_MASK_CLASS == InputType.TYPE_NULL

    fun commit(text: String) {
        if (text.isEmpty()) return
        val ic = ic ?: return
        if (raw && text == "\n") return key(KeyEvent.KEYCODE_ENTER)
        val start = if (composing && composeStart >= 0) composeStart else selStart
        ic.commitText(text, 1)
        model { replace(text, compose = false); true }
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
        model { replace(text.toString(), compose = true); true }
        composing = text.isNotEmpty()
        composeLength = text.length
        if (composeStart >= 0) expect(composeStart + text.length)
    }

    /** Leaves the composing text in the field as typed text. */
    fun finishComposing() {
        if (!composing) return
        ic?.finishComposingText()
        model { region = null; true }
        composing = false
        regionText = null
        if (selStart >= 0) expect(selStart)
    }

    /**
     * Makes the field's text from [before] characters (code points) before the cursor to [after] after it the
     * composing text, as it is (English reopening a word); with neither, the composing text ends where it is.
     * False, and nothing marked, when the field's cursor isn't ours: the region is placed by it (#280).
     */
    private fun composeRegion(before: Int, after: Int): Boolean {
        if (before == 0 && after == 0) return true.also { finishComposing() }
        val ic = ic ?: return false
        // Where [check] has just found the cursor ours, the text is the model's; else one read finds both
        val m = model
        val s = if (placed && m != null) Snapshot(m.text.substring(0, m.start), "", m.text.substring(m.end), selStart, selEnd)
            else snapshot(2 * before, 2 * after)?.takeIf { it.start == selStart } ?: return false
        if (s.start != s.end) return false
        val b = s.before.length - s.before.offsetByCodePoints(s.before.length, -minOf(before, s.before.codePointCount(0, s.before.length)))
        val a = s.after.offsetByCodePoints(0, minOf(after, s.after.codePointCount(0, s.after.length)))
        ic.setComposingRegion(selStart - b, selStart + a)
        model { (start - b >= 0 && start + a <= text.length).also { if (it) region = (start - b) until (start + a) } }
        composing = true
        composeStart = selStart - b
        composeLength = b + a
        regionText = s.before.takeLast(b) + s.after.take(a)
        expect(selStart)
        return true
    }

    /** Backspace: the selection, else the character (a whole emoji or accented letter) before the cursor. */
    fun deleteBefore() {
        val ic = ic ?: return
        if (selEnd > selStart && selStart >= 0) {
            ic.commitText("", 1)
            model { replace("", compose = false); true }
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
        model { delete(n, 0) }
        if (selStart >= 0) expect(selStart - n)
    }

    /**
     * An engine's edit around a commit: characters (code points) before and after the cursor, counted in
     * [model]'s text when [write] has just found it the field's ([known]), else in the field's.
     */
    private fun delete(before: Int, after: Int, known: Boolean) {
        val ic = ic ?: return
        val m = model?.takeIf { known }
        val text = m?.text?.substring(0, m.start) ?: ic.getTextBeforeCursor(2 * before, 0)?.toString().orEmpty()
        // The cursor moves back by the UTF-16 length of what goes.
        val gone = text.length - text.offsetByCodePoints(text.length, -minOf(before, text.codePointCount(0, text.length)))
        ic.deleteSurroundingTextInCodePoints(before, after)
        if (m != null) {
            val rest = m.text.substring(m.end)
            model { delete(gone, rest.offsetByCodePoints(0, minOf(after, rest.codePointCount(0, rest.length)))) }
        } else model = null
        if (selStart >= 0) expect(selStart - gone)
    }

    /** The field's text before the cursor (up to [max] characters): English's context. */
    fun textBefore(max: Int = 1000): String = ic?.getTextBeforeCursor(max, 0)?.toString().orEmpty()

    /** The start of the field's text after the cursor: the rest of a word English reopens. */
    fun textAfter(max: Int = 64): String = ic?.getTextAfterCursor(max, 0)?.toString().orEmpty()

    /** The text before the cursor (up to [max] characters) as English's checked edits left it, with no read; else the field's */
    fun knownBefore(max: Int): String {
        val m = model?.takeIf { checked && it.start == it.end } ?: return textBefore(max)
        return m.text.substring(maxOf(0, m.start - max), m.start)
    }

    /** Moves the cursor [by] characters from where it is (Mozc puts it between a pair of brackets). */
    fun moveCursor(by: Int) {
        if (by == 0 || selStart < 0) return
        val at = (selStart + by).coerceAtLeast(0)
        ic?.setSelection(at, at)
        model = null
        expect(at)
    }

    /** Moves the cursor [by] characters (whole code points), as far as the text goes: the space bar's swipe. */
    fun moveBy(by: Int) {
        val ic = ic ?: return
        if (selStart < 0) return
        val at = if (by < 0) {
            val before = ic.getTextBeforeCursor(-2 * by, 0) ?: return
            selStart - (before.length - Character.offsetByCodePoints(before, before.length, -minOf(-by, Character.codePointCount(before, 0, before.length))))
        } else {
            val after = ic.getTextAfterCursor(2 * by, 0) ?: return
            selEnd + Character.offsetByCodePoints(after, 0, minOf(by, Character.codePointCount(after, 0, after.length)))
        }
        ic.setSelection(at, at)
        model = null
        expect(at)
    }

    /** Delete's swipe: where it started (the cursor) and the text before it then */
    private var swipeEnd = -1
    private var swipeText = ""

    /** Delete's swipe: selects [words] words before the cursor (none: back to the cursor), deleted when [done]. */
    fun selectWordsBefore(words: Int, done: Boolean) {
        val ic = ic ?: return
        if (swipeEnd < 0) {
            if (selStart < 0) return
            swipeEnd = selStart
            swipeText = ic.getTextBeforeCursor(MAX_SWIPE, 0)?.toString().orEmpty()
        }
        model = null
        val end = swipeEnd
        val start = end - (swipeText.length - wordsStart(swipeText, words))
        if (!done) {
            ic.setSelection(start, end)
            return
        }
        swipeEnd = -1
        if (start < end) {
            ic.setSelection(start, end)
            ic.commitText("", 1)
            expect(start)
        } else ic.setSelection(end, end)
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

    /**
     * Whether the next letter starts a sentence (or a word, as the field asks): English's automatic Shift. From
     * the text English's checked edits left, as today's app does from its own copy, with no read; else the field's.
     */
    fun capsMode(): Boolean {
        if (capsFlags == 0) return false
        val m = model?.takeIf { checked && it.start == it.end }
        if (m != null) return TextUtils.getCapsMode(m.text.substring(0, m.start), m.start, info!!.inputType) != 0
        return (ic?.getCursorCapsMode(info!!.inputType) ?: 0) != 0
    }

    /** The capitals the field asks for (TextUtils.getCapsMode's modes), 0 for none */
    val capsFlags: Int get() {
        val type = info?.inputType ?: return 0
        if (type and InputType.TYPE_MASK_CLASS != InputType.TYPE_CLASS_TEXT) return 0
        return type and (InputType.TYPE_TEXT_FLAG_CAP_SENTENCES or InputType.TYPE_TEXT_FLAG_CAP_WORDS or
            InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS)
    }

    /** A key event: what it does to the text is the field's, so what we expect of it is gone */
    private fun key(code: Int) {
        model = null
        if (target == null) ime?.sendDownUpKeyEvents(code)
    }

    /** Undo (Ctrl+Z) and redo (Ctrl+Shift+Z): the field's own, as a hardware keyboard sends them */
    fun undo(redo: Boolean) {
        model = null
        val meta = KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON or (if (redo) KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_LEFT_ON else 0)
        val now = SystemClock.uptimeMillis()
        ic?.sendKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_Z, 0, meta))
        ic?.sendKeyEvent(KeyEvent(now, now, KeyEvent.ACTION_UP, KeyEvent.KEYCODE_Z, 0, meta))
    }

    /** Select all, cut, copy or paste ([android.R.id]'s), as the field's own menu does them */
    fun menuAction(id: Int) {
        model = null
        ic?.performContextMenuAction(id)
    }

    private fun expect(at: Int) {
        selStart = at
        selEnd = at
        expected.addLast(listOf(at, at, if (composing) composeStart else -1, if (composing) composeStart + composeLength else -1))
        if (expected.size > 64) expected.removeFirst()
    }

    /**
     * The field's selection changed; true when the user moved it (or the app changed the text): out of the
     * composing text, or to a place none of our recent edits put it. Updates come late, in order: one for
     * the last letter of a word can arrive after the word's commit, while the next word already composes.
     * Where [checked], one of ours must also have the composing text where our edit left it: an app that
     * dropped or moved it changed the field (#280).
     */
    fun selectionChanged(newStart: Int, newEnd: Int, candidatesStart: Int, candidatesEnd: Int): Boolean {
        val out = candidatesStart >= 0 && (newStart < candidatesStart || newEnd > candidatesEnd)
        val ours = if (out) -1 else expected.indexOfFirst {
            it[0] == newStart && it[1] == newEnd && (!checked || it[2] == candidatesStart && it[3] == candidatesEnd)
        }
        if (ours >= 0) {
            repeat(ours) { expected.removeFirst() } // the edits before it were reported already
            movedInside = -1
            return false
        }
        // Where our edit left the selection, but not the composing text
        val moved = !out && expected.any { it[0] == newStart && it[1] == newEnd }
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
        val external = out || moved || !(composing && candidatesStart >= 0 && quiet)
        // The user's cursor in the word being typed; else what the field has is to be read again
        if (movedInside >= 0) model { region?.let { start = it.first + movedInside; end = start } != null }
        else if (external) model = null
        return external
    }

    fun beginBatch() = ic?.beginBatchEdit()
    fun endBatch() = ic?.endBatchEdit()
}
