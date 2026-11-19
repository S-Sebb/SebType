package dev.sebb.sebtype

import android.inputmethodservice.InputMethodService
import android.text.InputType
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.ExtractedText
import android.view.inputmethod.ExtractedTextRequest
import android.view.inputmethod.InputConnection
import dev.sebb.sebtype.core.NativeState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy

class EditorTest {
    /** How a field answers getExtractedText */
    private enum class Extract {
        /** The whole text */
        WHOLE,
        /** None: it can't say where its cursor is */
        NONE,
        /** Four characters either side of the selection, from where they start (as getSurroundingText answers) */
        WINDOW,
        /** A part of the text, as for a change, which doesn't say where the selection is in the rest */
        PARTIAL,
    }

    /**
     * A text field as its InputConnection shows it: the text, the selection and the composing region. Each change
     * sends a selection update, which the keyboard hears of later ([Ime.update]).
     */
    private class Field(var text: String, var cursor: Int, val extract: Extract = Extract.WHOLE, val blind: Boolean = false,
                        /** The most getTextBeforeCursor and getTextAfterCursor give, whatever is asked */
                        val limit: Int = Int.MAX_VALUE) {
        var end = cursor
        /** The keyboard's reads of the field so far */
        var reads = 0
        /** The editor actions the keyboard sent */
        val actions = mutableListOf<Int>()
        var region: IntRange? = null
        /** An app that reports each edit's selection part-way too: the old text gone, the new not in yet */
        var intermediate = false
        /** Updates sent and not yet heard of: the selection's start and end, the composing text's start and end */
        val updates = ArrayDeque<IntArray>()
        private fun changed() {
            updates += intArrayOf(cursor, end, region?.first ?: -1, region?.let { it.last + 1 } ?: -1)
        }

        /** The user puts the cursor at [at]; the composing text stays marked, as an EditText keeps it. */
        fun tap(at: Int) {
            cursor = at
            end = at
            changed()
        }

        /**
         * The app's own edit: the text from [from] to [to] made [s], the composing text left where it is; a
         * selection after it moves with its text, as an EditText's does
         */
        fun edit(from: Int, to: Int, s: String) {
            text = text.substring(0, from) + s + text.substring(to)
            if (to <= cursor) {
                cursor += s.length - (to - from)
                end += s.length - (to - from)
            }
            changed()
        }

        /** The app ends the composing text itself, leaving it as text */
        fun dropComposing() {
            region = null
            changed()
        }

        /** A key event: Delete takes the selection, else the character before the cursor */
        fun key(code: Int) {
            if (code == KeyEvent.KEYCODE_DEL && end > cursor) {
                text = text.removeRange(cursor, end)
                end = cursor
                changed()
            } else if (code == KeyEvent.KEYCODE_DEL && cursor > 0) {
                text = text.removeRange(cursor - 1, cursor)
                cursor--
                end--
                changed()
            }
        }

        private fun replace(with: String, compose: Boolean) {
            val r = region ?: (cursor until end)
            text = text.substring(0, r.first) + with + text.substring(r.last + 1)
            if (intermediate) {
                cursor = r.first
                end = r.first
                region = null
                changed()
            }
            cursor = r.first + with.length
            end = cursor
            region = if (compose && with.isNotEmpty()) r.first until cursor else null
            changed()
        }

        private fun extracted(): ExtractedText? {
            val from = when (extract) {
                Extract.NONE -> return null
                Extract.WINDOW -> maxOf(0, cursor - 4)
                else -> 0
            }
            val to = when (extract) {
                Extract.WINDOW -> minOf(text.length, end + 4)
                Extract.PARTIAL -> minOf(text.length, end + 1)
                else -> text.length
            }
            return ExtractedText().also {
                it.text = text.substring(from, to)
                it.startOffset = from
                it.partialStartOffset = if (extract == Extract.PARTIAL) 0 else -1
                it.partialEndOffset = to
                it.selectionStart = cursor - from
                it.selectionEnd = end - from
            }
        }

        val connection = Proxy.newProxyInstance(InputConnection::class.java.classLoader, arrayOf(InputConnection::class.java)) { _, method, args ->
            if (method.name.startsWith("get")) reads++
            when (method.name) {
                "getTextBeforeCursor" -> if (blind) null else text.substring(maxOf(0, cursor - minOf(limit, args[0] as Int)), cursor)
                "getTextAfterCursor" -> if (blind) null else text.substring(end, minOf(text.length, end + minOf(limit, args[0] as Int)))
                "getSelectedText" -> if (blind) null else text.substring(cursor, end)
                "getExtractedText" -> if (blind) null else extracted()
                "getCursorCapsMode" -> 0
                "setSelection" -> true.also { cursor = args[0] as Int; end = args[1] as Int; changed() }
                // As BaseInputConnection's: from the composing text's edges where they are outside the selection
                "deleteSurroundingText", "deleteSurroundingTextInCodePoints" -> true.also {
                    val from = minOf(cursor, region?.first ?: cursor)
                    val to = maxOf(end, region?.let { it.last + 1 } ?: end)
                    val b = minOf(args[0] as Int, from)
                    text = text.substring(0, from - b) + text.substring(from, to) + text.substring(minOf(text.length, to + args[1] as Int))
                    cursor -= b
                    end -= b
                    region = region?.let { (it.first - b) until (it.last + 1 - b) }
                    changed()
                }
                "setComposingRegion" -> true.also { region = (args[0] as Int) until (args[1] as Int); changed() }
                "setComposingText" -> true.also { replace(args[0].toString(), compose = true) }
                "commitText" -> true.also { replace(args[0].toString(), compose = false) }
                "finishComposingText" -> true.also { region = null; changed() }
                "performEditorAction" -> true.also { actions += args[0] as Int }
                else -> if (method.returnType == Boolean::class.javaPrimitiveType) true else null
            }
        } as InputConnection
    }

    /**
     * The keyboard as SebTypeIme wires it, around an English engine that knows words of letters: the engine's
     * states go into the field through [Editor.write], as SebTypeIme.show does; the field's updates go through
     * [Editor.selectionChanged], one that isn't ours reads the field again ([Keys.reread]); keys go through
     * [Keys.type]; and the engine's results come back in order. The test hands the keyboard each update
     * ([update]) and result ([result]) in the order it picks.
     */
    private class Ime(var field: Field) {
        /** The input method service: its field's connection and the arrow keys it sends */
        val service = object : InputMethodService() {
            override fun getCurrentInputConnection() = field.connection
            override fun sendDownUpKeyEvents(keyEventCode: Int) = field.key(keyEventCode)
        }
        val editor = Editor(service)
        private val keys = Keys()
        private val results = ArrayDeque<() -> Unit>()
        private var preedit = ""
        // The engine thread's word, its cursor in it, and the correction Backspace would take back
        private var word = ""
        private var at = 0
        var correction: Pair<String, String>? = null

        init {
            editor.checked = true
            start(field)
            editor.around()
        }

        /** [field], a text field asking for sentences' capitals, comes up with its selection */
        private fun start(field: Field) = editor.start(EditorInfo().apply {
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
            initialSelStart = field.cursor
            initialSelEnd = field.end
        }, FieldKind.of(null))

        /** The engine's state: [word] typed, after its edit to the field */
        private fun state(word: String, commit: String = "", delete: Int = 0, recompose: Boolean = false, before: Int = 0,
                          after: Int = 0, taken: Boolean = true) = NativeState(taken, commit, delete, 0, 0, recompose, before, after,
            if (word.isEmpty()) arrayOf() else arrayOf(word), BooleanArray(if (word.isEmpty()) 0 else 1), -1, arrayOf(), arrayOf(), -1)

        /** SebTypeIme.post: [st] shown unless a read since made it stale, with [then] the key's own edit */
        private fun post(key: Keys.Key?, st: NativeState, then: (() -> Unit)? = null) {
            val asked = keys.ask()
            results += {
                if (keys.fresh(asked)) show(st, then)
                key?.done()
                // SebTypeIme.onKey's NativeCore.after: the Shift, and with all shown, the engine's copy of the text
                if (key != null) {
                    editor.capsMode()
                    if (results.isEmpty()) editor.knownBefore(64)
                }
            }
        }

        /** SebTypeIme.show */
        private fun show(st: NativeState, then: (() -> Unit)? = null): Boolean {
            if (!editor.write(st, st.preedit, then)) {
                context()
                return false
            }
            preedit = st.preedit
            return true
        }

        /** English's read of the field (SebTypeIme.englishContext): the word the cursor is after reopened, where it may be */
        private fun context(): Unit = keys.reread {
            val around = editor.around()
            val b = if (around.reopen) around.before.takeLastWhile { it.isLetter() }.length else 0
            val a = if (b > 0) around.after.takeWhile { it.isLetter() }.length else 0
            word = around.before.takeLast(b) + around.after.take(a)
            at = b
            correction = null
            post(null, state(word, recompose = b > 0, before = b, after = a))
        }

        /** A letter: in a word reopened mid-way, the word is narrowed to the part before the cursor first */
        fun key(c: Char) = keys.type { key ->
            val narrow = at < word.length
            val before = at
            word = word.take(at) + c
            at = word.length
            correction = null
            post(key, state(word, recompose = narrow, before = before))
        }

        /** Space: the word before the cursor goes in as typed, with a space */
        fun space() = keys.type { key ->
            val narrow = at < word.length
            val before = at
            val commit = word.take(at) + " "
            word = ""
            at = 0
            correction = null
            post(key, state("", commit, recompose = narrow, before = before))
        }

        /** Backspace: right after a correction, the word as typed back; with nothing typed, the field's character */
        fun backspace() = keys.type { key ->
            val c = correction
            correction = null
            when {
                c != null -> {
                    word = c.first
                    at = word.length
                    post(key, state(word, delete = c.second.length + 1))
                }
                word.isEmpty() -> post(key, state("", taken = false)) { editor.deleteBefore() }
                else -> {
                    word = word.dropLast(1)
                    at = word.length
                    post(key, state(word))
                }
            }
        }

        /** A suggestion tapped: it takes the word's place, with a space */
        fun pick(suggestion: String) {
            word = ""
            at = 0
            post(null, state("", "$suggestion "))
        }

        /** The engine's state with nothing typed (READY): its empty preedit goes into the field */
        fun ready() {
            word = ""
            at = 0
            post(null, state(""))
        }

        /** Another field comes up (SebTypeIme.onStartInput) */
        fun open(next: Field) {
            field = next
            start(next)
            keys.forget()
            preedit = ""
            context()
        }

        /** The next update, as SebTypeIme.onUpdateSelection takes it */
        fun update() {
            val (start, end, candidatesStart, candidatesEnd) = field.updates.removeFirst()
            val external = editor.selectionChanged(start, end, candidatesStart, candidatesEnd)
            if (external && preedit.isNotEmpty()) {
                editor.finishComposing()
                preedit = ""
            }
            if (external) context()
            else if (editor.movedInside >= 0) at = minOf(editor.movedInside, word.length)
            editor.capsMode() // SebTypeIme.autoShift
        }

        /** The next result */
        fun result() = results.removeFirst()()

        fun updates() {
            while (field.updates.isNotEmpty()) update()
        }

        fun results() {
            while (results.isNotEmpty()) result()
        }

        /**
         * Results and updates, until both are done. The results already queued come first: the update for a
         * write comes from the app, after the results posted on the keyboard's thread behind it.
         */
        fun settle() {
            while (field.updates.isNotEmpty() || results.isNotEmpty()) {
                results()
                updates()
            }
        }
    }

    /**
     * #280: the cursor moved into "hello", then into "world" before the first reopen came back. That one was
     * read at he|llo: it isn't written at wo|rld, where its region (2 before, 3 after) would take "world" and
     * leave the keyboard composing the wrong word; the field is read again and "world" reopened.
     */
    @Test
    fun aReopenReadBeforeTheCursorMovedAgainIsNotApplied() {
        val field = Field("hello world", 11)
        val ime = Ime(field)
        field.tap(2)
        ime.update()
        field.tap(8)
        ime.result()
        assertNull(field.region)
        ime.settle()
        assertEquals(6 until 11, field.region)
        assertEquals("hello world", field.text)
    }

    /**
     * #280: x typed into "hello" reopened at he|llo, the cursor moved to hello wo|rld and y typed there, all
     * before x's result came. x's result, asked for at he|llo, would narrow "world" and write over it
     * ("hello hexrld"); it is dropped, and no key is lost: x and y go in at the cursor in the order typed, as
     * they do in today's app when its text reaches the app after the tap.
     */
    @Test
    fun keysTypedAroundACursorMoveAreEachTypedOnce() {
        val field = Field("hello world", 11)
        val ime = Ime(field)
        field.tap(2)
        ime.settle()
        assertEquals(0 until 5, field.region)
        ime.key('x')
        field.tap(8)
        ime.updates()
        ime.key('y')
        ime.settle()
        assertEquals("hello woxyrld", field.text)
        assertEquals(10, field.cursor)
    }

    /**
     * #280: x typed into "hello" reopened at he|llo, then the cursor moved to hello wo|rld and back to he|llo,
     * both before the keyboard heard of either. The update for the way back is where reopening "hello" left the
     * cursor, but it isn't ours: had it been taken for ours, the keyboard would place "hello" by the cursor
     * at "world" and x would go over "world".
     */
    @Test
    fun aCursorBackWhereOurEditLeftItIsTheUsers() {
        val field = Field("hello world", 11)
        val ime = Ime(field)
        field.tap(2)
        ime.settle()
        ime.key('x')
        field.tap(8)
        field.tap(2)
        ime.updates()
        ime.settle()
        assertEquals("hexllo world", field.text)
        assertEquals(3, field.cursor)
    }

    /** #280: a READY strip asked for before a move, whose empty preedit would take the word now composing, is dropped. */
    @Test
    fun aReadyStripAskedBeforeTheCursorMovedIsDropped() {
        val field = Field("hello world", 11)
        val ime = Ime(field)
        field.tap(2)
        ime.settle()
        ime.ready()
        field.tap(8)
        ime.updates()
        ime.settle()
        assertEquals("hello world", field.text)
        assertEquals(6 until 11, field.region)
    }

    /**
     * #280: x typed into "hello" reopened at he|llo, the cursor moved to hello wo|rld and back to he|llo, and the
     * keyboard heard of the move to wo|rld only: its read of the field (he|llo) and x's replay came back before
     * the update for the way back. The read's cursor isn't the field's: had "hello" been reopened by it, it would
     * be marked at wo|rld, and x would go over "world" ("hello hexrld").
     */
    @Test
    fun aWordIsReopenedOnlyWhereTheFieldHasTheCursor() {
        for (extract in listOf(Extract.WHOLE, Extract.NONE)) {
            val field = Field("hello world", 11, extract)
            val ime = Ime(field)
            field.tap(2)
            ime.settle()
            ime.key('x')
            field.tap(8)
            field.tap(2)
            ime.update()
            ime.results()
            assertEquals("hexllo world", field.text)
            ime.settle()
            assertEquals("hexllo world", field.text)
            assertEquals(3, field.cursor)
            // The way back is the user's: the word x went into is reopened; a field that can't say where its
            // cursor is has none reopened
            assertEquals(if (extract == Extract.WHOLE) 0 until 6 else null, field.region)
        }
    }

    /** #280: x written at he|llo, then y, z and q typed before a move: they each go in once, in order, at the new cursor */
    @Test
    fun severalKeysInReplay() {
        val field = Field("hello world", 11)
        val ime = Ime(field)
        field.tap(2)
        ime.settle()
        ime.key('x')
        ime.result()
        ime.updates() // x's
        ime.key('y')
        ime.key('z')
        ime.key('q')
        field.tap(8) // hexllo w|orld
        ime.update()
        ime.settle()
        assertEquals("hexllo wyzqorld", field.text)
        assertEquals(11, field.cursor)
    }

    /** #280: the cursor moved again while keys were replayed after a move: they go in at the last cursor */
    @Test
    fun aMoveDuringReplay() {
        val field = Field("hello world", 11)
        val ime = Ime(field)
        field.tap(2)
        ime.settle()
        ime.key('x')
        ime.key('y')
        field.tap(8)
        ime.update()
        ime.result()
        ime.result()
        ime.result() // the read at wo|rld
        field.tap(3)
        ime.result() // x again, at wo|rld
        ime.update()
        ime.settle()
        assertEquals("helxylo world", field.text)
        assertEquals(5, field.cursor)
    }

    /**
     * #280: a suggestion tapped and a space typed for "hello" reopened at he|llo, then the cursor moved to
     * wo|rld before either came back. The suggestion was for "hello": it is dropped. The space is a key: it goes
     * in at the cursor.
     */
    @Test
    fun aSuggestionTapAndASpaceInFlight() {
        val field = Field("hello world", 11)
        val ime = Ime(field)
        field.tap(2)
        ime.settle()
        ime.pick("help")
        ime.space()
        field.tap(8)
        ime.update()
        ime.settle()
        assertEquals("hello wo rld", field.text)
        assertEquals(9, field.cursor)
    }

    /** #280: an app that reports each edit's selection part-way too: the keys still go in once, in order */
    @Test
    fun anAppReportingIntermediateSelections() {
        val field = Field("hello world", 11)
        field.intermediate = true
        val ime = Ime(field)
        field.tap(2)
        ime.settle()
        ime.key('x')
        ime.result()
        ime.update()
        ime.update()
        ime.key('y')
        ime.update()
        ime.key('z')
        ime.settle()
        assertEquals("hexyzllo world", field.text)
        assertEquals(5, field.cursor)
    }

    /**
     * #280: "teh " corrected to "the ", Backspace pressed, then the cursor put after "I " before Backspace's
     * result came, and that result came before the update for the move. The result takes back "the " before
     * the cursor where it was: written at the new cursor, it would take "I " and put "teh" there. The field
     * isn't as the engine knows it, so nothing goes in; the field is read again and Backspace goes in there.
     */
    @Test
    fun anAutocorrectUndoAfterAMoveDeletesNothingThere() {
        val field = Field("I saw the ", 10)
        val ime = Ime(field)
        ime.correction = "teh" to "the"
        ime.backspace()
        field.tap(2)
        ime.result()
        assertEquals("I saw the ", field.text)
        ime.settle()
        assertEquals("Isaw the ", field.text)
        assertEquals(1, field.cursor)
    }

    /**
     * #280: a letter's result that came before the update for a move goes into the word still composing, as in
     * today's app: a letter only sets the composing text, without a read first (the bar: no less safe than today's
     * app, no slower than main). The move is heard next, and the word the letter went into is reopened.
     */
    @Test
    fun aLetterWrittenBeforeAMoveIsHeardGoesIntoTheWord() {
        val field = Field("hello world", 11)
        val ime = Ime(field)
        field.tap(5)
        ime.settle()
        ime.key('x')
        field.tap(8)
        ime.result()
        assertEquals("hellox world", field.text)
        ime.settle()
        assertEquals("hellox world", field.text)
        assertEquals(0 until 6, field.region)
    }

    /**
     * #280: a suggestion tapped for "hello", its result come before the update for a move to "world": it takes
     * the place of the word still composing, as in today's app, which reads nothing before a commit either (the
     * bar: no less safe than today's app, no slower than main). The move is heard next and "world" reopened.
     */
    @Test
    fun aSuggestionPickedBeforeAMoveIsHeardTakesTheWordsPlace() {
        val field = Field("hello world", 11)
        val ime = Ime(field)
        field.tap(5)
        ime.settle()
        ime.pick("help")
        field.tap(8)
        ime.settle()
        assertEquals("help  world", field.text)
    }

    /**
     * #280: a field whose extracted text is a window of it (from startOffset, as getSurroundingText answers):
     * where the cursor is in the field is the window's start and the cursor in it. "world" is reopened at
     * wo|rld and x goes in at the cursor.
     */
    @Test
    fun aWindowOfTheTextIsPlacedByWhereItStarts() {
        val field = Field("hello world", 11, Extract.WINDOW)
        val ime = Ime(field)
        field.tap(8)
        ime.settle()
        assertEquals(6 until 11, field.region)
        ime.key('x')
        ime.settle()
        assertEquals("hello woxrld", field.text)
        assertEquals(9, field.cursor)
    }

    /** #280: a part of the text extracted (one that changed) doesn't say where the cursor is: no word is reopened by it */
    @Test
    fun aPartOfTheTextIsNotWhereTheCursorIs() {
        val field = Field("hello world", 11, Extract.PARTIAL)
        val ime = Ime(field)
        field.tap(8)
        ime.settle()
        assertNull(field.region)
        ime.key('x')
        ime.settle()
        assertEquals("hello woxrld", field.text)
    }

    /**
     * #280: a letter or a space typed reads nothing from the field (main's reads 3 a letter: the Shift after the
     * key and after its update, and the engine's copy of the text). It goes in by the composing text and the
     * cursor, as in today's app, and the Shift and the engine's copy come from the text English's edits left.
     */
    @Test
    fun typingDoesntReadTheField() {
        val field = Field("I saw ", 6)
        val ime = Ime(field)
        for (c in "hello ") {
            field.reads = 0
            if (c == ' ') ime.space() else ime.key(c)
            ime.settle()
            assertEquals(0, field.reads)
        }
        assertEquals("I saw hello ", field.text)
    }

    /**
     * #280: the app ended the composing text "hello" itself, as text. Its update has the cursor where our last
     * letter left it, but no composing text: the field changed. Taken for ours, x's composing text would go in
     * at the cursor beside "hello" ("hellohellox"); the field is read again and "hello" reopened for x.
     */
    @Test
    fun theAppEndingTheComposingTextIsTheFieldsChange() {
        val field = Field(" world", 0)
        val ime = Ime(field)
        for (c in "hello") ime.key(c)
        ime.settle()
        assertEquals(0 until 5, field.region)
        field.dropComposing()
        ime.update()
        ime.key('x')
        ime.settle()
        assertEquals("hellox world", field.text)
    }

    /**
     * #280: the app changed the first letter of the word being typed without moving the cursor or the composing
     * text, so no update says so. The next letter's setComposingText writes over it, as in today's app, which
     * reads nothing before a letter either (the bar: no less safe than today's app, no slower than main). An
     * edit of a range, which reads first, checks all the composing text.
     */
    @Test
    fun anAppEditInsideTheWordGoesUnnoticedAsInTodaysApp() {
        val field = Field("", 0)
        val ime = Ime(field)
        repeat(70) { ime.key('a') }
        ime.settle()
        field.edit(0, 1, "b")
        ime.updates()
        ime.key('x')
        ime.settle()
        assertEquals("a".repeat(70) + "x", field.text)
    }

    /**
     * #280: a field that gives nothing when read: where its cursor is and what is around it are unknown, not
     * empty. Backspace after "teh" corrected to "the " doesn't take the correction back there (it would delete
     * four characters it can't see); it goes in as the field's own Backspace.
     */
    @Test
    fun anUnreadableFieldTakesNoCorrectionBack() {
        val field = Field("I saw the ", 10, Extract.NONE, blind = true)
        val ime = Ime(field)
        ime.correction = "teh" to "the"
        ime.backspace()
        ime.settle()
        assertEquals("I saw the", field.text)
        assertNull(field.region)
    }

    /** #325: Delete's swipe selects a word for each step, back and forth, and deletes what is selected when let go */
    @Test
    fun aDeleteSwipe() {
        val field = Field("one two three", 13)
        val ime = Ime(field)
        for (words in listOf(1, 2, 1)) {
            ime.editor.selectWordsBefore(words, false)
            ime.settle()
        }
        assertEquals(8 until 13, field.cursor until field.end)
        ime.editor.selectWordsBefore(1, true)
        ime.settle()
        assertEquals("one two ", field.text)
        assertEquals(8, field.cursor)
    }

    /**
     * #325: the app put "zero " before the text while Delete was swiped: the selection moved with its words, so
     * where the swipe started isn't where it was. The swipe ends and deletes nothing; placed where it started,
     * it would take "o thr".
     */
    @Test
    fun anAppEditDuringADeleteSwipeEndsIt() {
        val field = Field("one two three", 13)
        val ime = Ime(field)
        ime.editor.selectWordsBefore(1, false)
        ime.settle()
        field.edit(0, 0, "zero ")
        ime.editor.selectWordsBefore(2, false)
        ime.editor.selectWordsBefore(2, true)
        ime.settle()
        assertEquals("zero one two three", field.text)
    }

    /**
     * #325: the cursor put after "one" while Delete was swiped, before the keyboard heard of it: the swipe
     * ends and deletes nothing.
     */
    @Test
    fun aCursorMoveDuringADeleteSwipeEndsIt() {
        val field = Field("one two three", 13)
        val ime = Ime(field)
        ime.editor.selectWordsBefore(1, false)
        ime.settle()
        field.tap(3)
        ime.editor.selectWordsBefore(1, true)
        assertEquals("one two three", field.text)
        assertEquals(3, field.cursor)
    }

    /** #325: a cancelled touch, or Delete swiped back to no words, deletes nothing; the selection goes */
    @Test
    fun aCancelledDeleteSwipeDeletesNothing() {
        val field = Field("one two three", 13)
        val ime = Ime(field)
        ime.editor.selectWordsBefore(1, false)
        ime.settle()
        ime.editor.selectWordsBefore(0, true)
        assertEquals("one two three", field.text)
        assertEquals(13 until 13, field.cursor until field.end)
    }

    /**
     * #325: a field that can't say where its cursor is, here one whose reads give at most four characters ("hree"
     * of "one two three"): nothing tells where the text read starts, so each step further is a Backspace, at
     * once, as in today's app. Taken for the text's start, "hree" would have gone as a word.
     */
    @Test
    fun aDeleteSwipeWhereTheCursorIsUnknownIsBackspaces() {
        val field = Field("one two three", 13, Extract.NONE, limit = 4)
        val ime = Ime(field)
        ime.editor.selectWordsBefore(2, false)
        assertEquals("one two thr", field.text)
        ime.editor.selectWordsBefore(1, false)
        ime.editor.selectWordsBefore(2, false)
        ime.editor.selectWordsBefore(2, true)
        assertEquals("one two thr", field.text)
    }

    /**
     * #325: a field that can't say where its cursor is, and gave none when it came up, with "def" selected in
     * it: the swipe's Backspace is the field's own, which takes the selection. One of ours would take the "c"
     * before it and leave "def" selected.
     */
    @Test
    fun aDeleteSwipeWhereTheCursorIsUnknownTakesTheSelection() {
        val field = Field("abcdefghi", 3, Extract.NONE).also { it.end = 6 }
        val service = object : InputMethodService() {
            override fun getCurrentInputConnection() = field.connection
            override fun sendDownUpKeyEvents(keyEventCode: Int) = field.key(keyEventCode)
        }
        val editor = Editor(service)
        editor.start(EditorInfo().apply {
            inputType = InputType.TYPE_CLASS_TEXT
            initialSelStart = -1
            initialSelEnd = -1
        }, FieldKind.of(null))
        editor.selectWordsBefore(1, false)
        assertEquals("abcghi", field.text)
    }

    /**
     * #325: a field that can't say where its cursor is, with "three" marked as composing: the Backspace goes
     * before the cursor, not before the composing text ("one twothree").
     */
    @Test
    fun aDeleteSwipeWhereTheCursorIsUnknownDeletesBeforeTheCursor() {
        val field = Field("one two three", 13, Extract.NONE)
        val ime = Ime(field)
        field.region = 8 until 13
        ime.editor.selectWordsBefore(1, false)
        ime.editor.selectWordsBefore(1, true)
        assertEquals("one two thre", field.text)
    }

    /**
     * #325: an emoji where Delete's swipe's read starts (2000 characters before the cursor), at each character
     * of it: a flag, a skin tone and a ZWJ sequence. Two words reach back to the read's start; the words go only
     * back to the space after the emoji, and the emoji stays whole. A read without a space deletes nothing.
     */
    @Test
    fun aDeleteSwipeDoesntSplitAnEmojiAtTheReadsLimit() {
        for (emoji in listOf("😀", "🇬🇧", "👍🏽", "👩‍💻")) for (cut in emoji.indices) {
            // "x", then the read: [cut] characters into the emoji to the cursor
            val text = "x$emoji " + "a".repeat(2000 + cut - emoji.length - 1)
            val field = Field(text, text.length)
            val ime = Ime(field)
            ime.editor.selectWordsBefore(2, false)
            ime.editor.selectWordsBefore(2, true)
            assertEquals("$emoji $cut", "x$emoji ", field.text)
        }
        val text = "x🇬🇧" + "a".repeat(1997)
        val field = Field(text, text.length)
        val ime = Ime(field)
        ime.editor.selectWordsBefore(2, false)
        ime.editor.selectWordsBefore(2, true)
        assertEquals(text, field.text)
    }

    /**
     * #325: whitespace that starts a character cluster, in a read that doesn't start at the start of the text:
     * CR LF, and a space, a no-break space and an ideographic space each with an accent. The words go back to the
     * cluster's end, not into it ("xa\r" left, or an accent without its space).
     */
    @Test
    fun aDeleteSwipeDoesntSplitWhitespaceFromWhatFollows() {
        for (space in listOf("\r\n", " \u0301", "\u00A0\u0301", "\u3000\u0301")) {
            // "x", then the read: from "a" to the cursor
            val text = "xa$space" + "b".repeat(1999 - space.length)
            val field = Field(text, text.length)
            val ime = Ime(field)
            ime.editor.selectWordsBefore(2, false)
            ime.editor.selectWordsBefore(2, true)
            assertEquals(space, "xa$space", field.text)
        }
    }

    /**
     * #325: a field that gives less than asked for, four characters either side of the cursor: the first step
     * reads "hree", not where its word starts, and selects nothing of it. Let go, what was selected goes, and
     * no more: a read then of "wo three" would take all "three".
     */
    @Test
    fun aDeleteSwipeDeletesOnlyWhatItSelected() {
        val field = Field("one two three", 13, Extract.WINDOW)
        val ime = Ime(field)
        ime.editor.selectWordsBefore(1, false)
        ime.settle()
        val selected = field.cursor until field.end
        ime.editor.selectWordsBefore(1, true)
        assertEquals("one two three".removeRange(selected), field.text)
    }

    /** #325: another field came up during Delete's swipe: nothing of the swipe goes into it */
    @Test
    fun aDeleteSwipeEndsWithItsField() {
        val ime = Ime(Field("one two three", 13))
        ime.editor.selectWordsBefore(1, false)
        val next = Field("four five", 9)
        ime.open(next)
        ime.settle()
        ime.editor.selectWordsBefore(1, false)
        ime.editor.selectWordsBefore(1, true)
        assertEquals("four five", next.text)
        assertEquals(9, next.cursor)
    }

    /**
     * #325: the cursor put after "one", then the space bar swiped a character right, before the keyboard heard
     * of the move: the cursor goes from where the field has it.
     */
    @Test
    fun aSpaceSwipeGoesFromTheFieldsCursor() {
        val field = Field("one two three", 13)
        val ime = Ime(field)
        field.tap(3)
        ime.editor.moveBy(1)
        assertEquals(4, field.cursor)
        ime.editor.moveBy(-2)
        assertEquals(2, field.cursor)
    }

    /**
     * #325: the emoji panel's search, a text of the keyboard's own with no surrounding text and no key events
     * (Search.connection): both swipes move the cursor and delete in its text.
     */
    @Test
    fun theSwipesInASearch() {
        val field = Field("big smile", 9)
        val editor = Editor(null, field.connection)
        val search = Search(View(null)) {}
        // Search's own connection says where its cursor is, as the swipes need: BaseInputConnection doesn't. The
        // JVM's stand-ins for its Editable keep no text, so the swipes go into a field of the same shape.
        assertEquals(-1, search.connection.getExtractedText(ExtractedTextRequest(), 0)?.partialStartOffset)
        editor.start(search.info, FieldKind.of(null))
        editor.moveBy(-2)
        assertEquals(7, field.cursor)
        editor.moveBy(2)
        editor.selectWordsBefore(1, false)
        assertEquals(4 until 9, field.cursor until field.end)
        editor.selectWordsBefore(1, true)
        assertEquals("big ", field.text)
    }

    /** 日本語 in [field], as SebTypeIme writes Mozc's states: its updates heard as they come ([hear]) */
    private class Japanese(val field: Field) {
        val editor = Editor(null, field.connection).also {
            it.start(EditorInfo().apply {
                inputType = InputType.TYPE_CLASS_TEXT
                initialSelStart = field.cursor
                initialSelEnd = field.end
            }, FieldKind.of(null))
        }

        fun mozc(preedit: String = "", commit: String = "", delete: Int = 0) = NativeState(true, commit, delete, 0, 0, false, 0, 0,
            if (preedit.isEmpty()) arrayOf() else arrayOf(preedit), BooleanArray(if (preedit.isEmpty()) 0 else 1), -1, arrayOf(), arrayOf(), -1)

        fun write(st: NativeState) = editor.write(st, st.preedit).also { hear() }

        /** Mozc's answer to Undo after it committed [word] read as [reading]: the reading back in the word's place */
        fun undo(word: String, reading: String) =
            mozc(reading, delete = word.length).let { editor.engineUndo(it, it.preedit, "") }.also { hear() }

        /** The field's updates; whether one wasn't ours */
        fun hear(): Boolean {
            var external = false
            while (field.updates.isNotEmpty()) field.updates.removeFirst().let { if (editor.selectionChanged(it[0], it[1], it[2], it[3])) external = true }
            return external
        }

        /** nihongo typed after the text, 日本語 picked */
        fun commit() {
            write(mozc("にほんご"))
            write(mozc(commit = "日本語"))
        }
    }

    /** #379: Undo right after a conversion: Mozc's reading back in its place, to convert again. */
    @Test
    fun undoAfterAConversionBringsItsReadingBack() {
        val ja = Japanese(Field("abc", 3))
        ja.commit()
        assertEquals("abc日本語", ja.field.text)
        assertTrue(ja.undo("日本語", "にほんご"))
        assertEquals("abcにほんご", ja.field.text)
        assertEquals(3 until 7, ja.field.region)
    }

    /**
     * #379: watashiha converted to 私は and 私 picked: Mozc commits it and は stays composing. Undo takes 私 back
     * from before は: the whole reading composing again, and the field's update is ours (no reset of Mozc).
     */
    @Test
    fun undoAfterAPartialConversionReopensIt() {
        val ja = Japanese(Field("ab", 2))
        ja.write(ja.mozc("私は"))
        ja.write(ja.mozc("は", commit = "私"))
        assertEquals("ab私は", ja.field.text)
        val st = ja.mozc("わたしは", delete = 1)
        assertTrue(ja.editor.engineUndo(st, st.preedit, "は"))
        assertFalse(ja.hear())
        assertEquals("abわたしは", ja.field.text)
        assertEquals(2 until 6, ja.field.region)
        assertEquals(6, ja.field.cursor)
    }

    /** #379: the cursor moved after the conversion: Mozc's undo would replace other text (bc), so the app's goes. */
    @Test
    fun undoAfterTheCursorMovedLeavesTheTextToTheApp() {
        val ja = Japanese(Field("abc", 3))
        ja.commit()
        ja.field.tap(3)
        ja.hear()
        assertFalse(ja.undo("日本語", "にほんご"))
        assertEquals("abc日本語", ja.field.text)
    }

    /** #379: text pasted after the conversion: Mozc's undo would take the paste for its commit. */
    @Test
    fun undoAfterAPasteLeavesThePaste() {
        val ja = Japanese(Field("abc", 3))
        ja.commit()
        ja.editor.menuAction(android.R.id.paste)
        ja.field.edit(6, 6, "xyz")
        assertFalse(ja.undo("日本語", "にほんご"))
        assertEquals("abc日本語xyz", ja.field.text)
    }

    /** #379: while typing with nothing to undo, Mozc takes Undo and changes nothing: the app's undo goes. */
    @Test
    fun undoThatChangesNothingLeavesItToTheApp() {
        val ja = Japanese(Field("", 0))
        ja.write(ja.mozc("にほんご"))
        val same = ja.mozc("にほんご")
        assertFalse(ja.editor.engineUndo(same, same.preedit, "にほんご"))
        assertEquals("にほんご", ja.field.text)
    }

    /**
     * #381: a field with an app's own action (actionLabel and actionId) gets that action on Enter, as the old app
     * sent it; a standard action gets its own, and a multi-line field that asks for no action gets a newline.
     */
    @Test
    fun enterSendsTheFieldsAction() {
        fun enter(options: Int, label: String?): Pair<String, List<Int>> {
            val field = Field("", 0)
            val editor = Editor(null, field.connection)
            val info = EditorInfo().apply {
                inputType = InputType.TYPE_CLASS_TEXT
                imeOptions = options
                actionLabel = label
                actionId = 42
            }
            editor.start(info, FieldKind.of(info))
            editor.enter()
            return field.text to field.actions
        }
        assertEquals("" to listOf(42), enter(EditorInfo.IME_ACTION_UNSPECIFIED, "Pay"))
        assertEquals("" to listOf(42), enter(EditorInfo.IME_ACTION_DONE, "Pay"))
        assertEquals("" to listOf(EditorInfo.IME_ACTION_SEARCH), enter(EditorInfo.IME_ACTION_SEARCH, null))
        assertEquals("\n" to listOf<Int>(), enter(EditorInfo.IME_ACTION_DONE or EditorInfo.IME_FLAG_NO_ENTER_ACTION, "Pay"))
    }
}
