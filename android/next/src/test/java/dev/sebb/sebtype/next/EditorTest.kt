package dev.sebb.sebtype.next

import android.inputmethodservice.InputMethodService
import android.text.InputType
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.ExtractedText
import android.view.inputmethod.InputConnection
import dev.sebb.sebtype.core.NativeState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
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
    private class Field(var text: String, var cursor: Int, val extract: Extract = Extract.WHOLE) {
        var end = cursor
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

        /** The app's own edit: [s] in at [at], what is after it moved on */
        fun insert(at: Int, s: String) {
            text = text.substring(0, at) + s + text.substring(at)
            fun moved(i: Int) = if (i >= at) i + s.length else i
            cursor = moved(cursor)
            end = moved(end)
            region = region?.let { moved(it.first) until moved(it.last + 1) }
            changed()
        }

        /** An arrow key */
        fun key(code: Int) {
            when (code) {
                KeyEvent.KEYCODE_DPAD_LEFT -> tap(maxOf(0, cursor - 1))
                KeyEvent.KEYCODE_DPAD_RIGHT -> tap(minOf(text.length, end + 1))
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
            when (method.name) {
                "getTextBeforeCursor" -> text.substring(maxOf(0, cursor - args[0] as Int), cursor)
                "getTextAfterCursor" -> text.substring(end, minOf(text.length, end + args[0] as Int))
                "getSelectedText" -> text.substring(cursor, end)
                "getExtractedText" -> extracted()
                "setSelection" -> true.also { cursor = args[0] as Int; end = args[1] as Int; changed() }
                "deleteSurroundingText", "deleteSurroundingTextInCodePoints" -> true.also {
                    val b = minOf(args[0] as Int, cursor)
                    text = text.substring(0, cursor - b) + text.substring(cursor, end) + text.substring(minOf(text.length, end + args[1] as Int))
                    cursor -= b
                    end -= b
                    changed()
                }
                "setComposingRegion" -> true.also { region = (args[0] as Int) until (args[1] as Int); changed() }
                "setComposingText" -> true.also { replace(args[0].toString(), compose = true) }
                "commitText" -> true.also { replace(args[0].toString(), compose = false) }
                "finishComposingText" -> true.also { region = null; changed() }
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
            start(field)
        }

        /** [field], a text field, comes up with its selection */
        private fun start(field: Field) = editor.start(EditorInfo().apply {
            inputType = InputType.TYPE_CLASS_TEXT
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
            }
        }

        /** SebTypeIme.show */
        private fun show(st: NativeState, then: (() -> Unit)? = null): Boolean {
            if (!editor.write(st, st.preedit, check = true, then)) {
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

        /** The user's swipes (SebTypeIme.onCursor, onDeleteWords): the word being typed goes in as typed, then [edit] */
        private fun swipe(edit: () -> Unit) {
            val asked = keys.ask()
            val flush = if (word.isNotEmpty()) state("", word) else null
            word = ""
            at = 0
            results += {
                if (flush != null && keys.fresh(asked)) show(flush)
                edit()
            }
        }

        fun swipeDelete(words: Int, done: Boolean) = swipe {
            editor.selectWordsBefore(words, done)
            if (done) context()
        }

        fun swipeSpace(by: Int) = swipe {
            editor.moveBy(by)
            context()
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
            // x types on in the word reopened; a field that can't say where its cursor is has none reopened
            assertEquals(if (extract == Extract.WHOLE) 0 until 3 else null, field.region)
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
     * #280: the cursor put after "hello" and delete swiped a word before the keyboard heard of the move. The
     * swipe starts where the field has the cursor, not at the end where the keyboard last had it ("world").
     */
    @Test
    fun theDeleteSwipeStartsWhereTheFieldHasTheCursor() {
        for (extract in listOf(Extract.WHOLE, Extract.NONE)) {
            val field = Field("hello world", 11, extract)
            val ime = Ime(field)
            field.tap(5)
            ime.swipeDelete(1, false)
            ime.swipeDelete(1, true)
            ime.settle()
            assertEquals(" world", field.text)
            assertEquals(0, field.cursor)
        }
    }

    /** #280: the space bar's swipe moves from where the field has the cursor, though the keyboard hasn't heard of it */
    @Test
    fun theSpaceSwipeMovesFromWhereTheFieldHasTheCursor() {
        // A field that can't say where its cursor is gets the arrow keys
        for (extract in listOf(Extract.WHOLE, Extract.NONE)) {
            val field = Field("hello world", 11, extract)
            val ime = Ime(field)
            field.tap(2)
            ime.swipeSpace(1)
            ime.settle()
            assertEquals(3, field.cursor)
            assertEquals("hello world", field.text)
        }
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

    /** #280: a letter's result that came before the update for a move goes in at the cursor, not into the word left */
    @Test
    fun aLetterWrittenAfterAMoveGoesInAtTheCursor() {
        val field = Field("hello world", 11)
        val ime = Ime(field)
        field.tap(5)
        ime.settle()
        ime.key('x')
        field.tap(8)
        ime.result()
        assertEquals("hello world", field.text)
        ime.settle()
        assertEquals("hello woxrld", field.text)
        assertEquals(9, field.cursor)
    }

    /** #280: a suggestion tapped for "hello", its result come before the update for a move to "world": it is dropped */
    @Test
    fun aSuggestionTappedBeforeAMoveIsDropped() {
        val field = Field("hello world", 11)
        val ime = Ime(field)
        field.tap(5)
        ime.settle()
        ime.pick("help")
        field.tap(8)
        ime.settle()
        assertEquals("hello world", field.text)
        assertEquals(6 until 11, field.region)
    }

    /**
     * #280: delete's swipe selected "world", then the app put "X " at the start before it was let go. The
     * selection it made was placed in the text before; the swipe stops, and nothing goes.
     */
    @Test
    fun aDeleteSwipeStopsWhenTheAppEditsTheText() {
        val field = Field("hello world", 11)
        val ime = Ime(field)
        ime.swipeDelete(1, false)
        ime.settle()
        assertEquals(6, field.cursor)
        assertEquals(11, field.end)
        field.insert(0, "X ")
        ime.swipeDelete(1, true)
        ime.settle()
        assertEquals("X hello world", field.text)
    }

    /** #280: delete's swipe started, then the cursor moved before it was let go: the swipe stops, and nothing goes */
    @Test
    fun aDeleteSwipeStopsWhenTheCursorMoves() {
        val field = Field("hello world", 11)
        val ime = Ime(field)
        ime.swipeDelete(1, false)
        ime.settle()
        field.tap(3)
        ime.swipeDelete(1, true)
        ime.settle()
        assertEquals("hello world", field.text)
    }

    /** #280: delete's swipe started in one field and let go in the next: nothing goes from the next */
    @Test
    fun aDeleteSwipeEndsWithItsField() {
        val field = Field("hello world", 11)
        val ime = Ime(field)
        ime.swipeDelete(1, false)
        ime.settle()
        val next = Field("good day", 8)
        ime.open(next)
        ime.settle()
        ime.swipeDelete(1, true)
        ime.settle()
        assertEquals("good day", next.text)
        assertEquals(8, next.cursor)
    }

    /**
     * #280: delete's swipe in a field that can't say where its cursor is, and the app made "world" "worlds"
     * before it was let go: the word goes as it is then, counted in the text before the cursor at the end.
     */
    @Test
    fun aDeleteSwipeWithoutACursorCountsTheWordsWhenLetGo() {
        val field = Field("hello world", 11, Extract.NONE)
        val ime = Ime(field)
        ime.swipeDelete(1, false)
        ime.settle()
        field.insert(11, "s")
        ime.swipeDelete(1, true)
        ime.settle()
        assertEquals("hello ", field.text)
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
}
