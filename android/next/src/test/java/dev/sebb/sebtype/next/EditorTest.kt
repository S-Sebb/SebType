package dev.sebb.sebtype.next

import android.view.inputmethod.ExtractedText
import android.view.inputmethod.InputConnection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy

class EditorTest {
    /**
     * A text field as its InputConnection shows it: the text, the selection and the composing region. Each change
     * sends a selection update, which the keyboard hears of later ([Ime.update]). One that can't [extract] its
     * text can't say where its cursor is either.
     */
    private class Field(var text: String, var cursor: Int, val extract: Boolean = true) {
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

        val connection = Proxy.newProxyInstance(InputConnection::class.java.classLoader, arrayOf(InputConnection::class.java)) { _, method, args ->
            when (method.name) {
                "getTextBeforeCursor" -> text.substring(maxOf(0, cursor - args[0] as Int), cursor)
                "getTextAfterCursor" -> text.substring(end, minOf(text.length, end + args[0] as Int))
                "getExtractedText" -> if (extract) ExtractedText().also {
                    it.text = text
                    it.selectionStart = cursor
                    it.selectionEnd = end
                } else null
                "setSelection" -> true.also { cursor = args[0] as Int; end = args[1] as Int; changed() }
                "deleteSurroundingText" -> true.also {
                    text = text.substring(0, cursor - args[0] as Int) + text.substring(cursor)
                    cursor -= args[0] as Int
                    end = cursor
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
     * The keyboard as SebTypeIme wires it, around an English engine that knows words of letters: the field's
     * updates go through [Editor.selectionChanged], one that isn't ours reads the field again
     * ([Keys.reread]), keys go through [Keys.type], and the engine's results come back in order, each written
     * where the field is then. The test hands the keyboard each update ([update]) and result ([result]) in the
     * order it picks.
     */
    private class Ime(val field: Field) {
        val editor = Editor(null, field.connection)
        private val keys = Keys()
        private val results = ArrayDeque<() -> Unit>()
        private var preedit = ""
        // The engine thread's word and its cursor in it
        private var word = ""
        private var at = 0

        // The field's selection when it opened
        init {
            editor.selectionChanged(field.cursor, field.end, -1, -1)
        }

        /**
         * The field's text from [before] to [after] the cursor made the word ([recompose]), [commit] put in its
         * place, then [word] composed
         */
        class Result(val recompose: Boolean, val before: Int, val after: Int, val word: String, val commit: String = "")

        private fun post(key: Keys.Key?, result: Result, show: (Result) -> Unit) {
            val asked = keys.ask()
            results += {
                if (keys.fresh(asked)) show(result)
                key?.done()
            }
        }

        private fun show(r: Result, around: Editor.Around? = null) {
            if (r.recompose && !editor.composeRegion(r.before, r.after, around?.text(r.before, r.after))) {
                editor.finishComposing()
                preedit = ""
                return context()
            }
            editor.commit(r.commit)
            editor.compose(r.word)
            preedit = r.word
        }

        /** English's read of the field: the word at the cursor reopened, where it can be placed */
        private fun context(): Unit = keys.reread {
            val around = editor.around()
            val b = if (around.reopen) around.before.takeLastWhile { it.isLetter() }.length else 0
            val a = if (around.reopen) around.after.takeWhile { it.isLetter() }.length else 0
            word = around.before.takeLast(b) + around.after.take(a)
            at = b
            post(null, Result(b + a > 0, b, a, word)) { if (editor.unchanged(around)) show(it, around) else context() }
        }

        /** A letter: in a word reopened mid-way, the word is narrowed to the part before the cursor first */
        fun key(c: Char) = keys.type { key ->
            val narrow = at < word.length
            val before = at
            word = word.take(at) + c
            at = word.length
            post(key, Result(narrow, before, 0, word)) { show(it) }
        }

        /** Space: the word before the cursor goes in as typed, with a space */
        fun space() = keys.type { key ->
            val narrow = at < word.length
            val before = at
            val commit = word.take(at) + " "
            word = ""
            at = 0
            post(key, Result(narrow, before, 0, "", commit)) { show(it) }
        }

        /** A suggestion tapped: it takes the word's place, with a space */
        fun pick(suggestion: String) {
            word = ""
            at = 0
            post(null, Result(false, 0, 0, "", "$suggestion ")) { show(it) }
        }

        /** The engine's state with nothing typed (READY): its empty preedit goes into the field */
        fun ready() {
            word = ""
            at = 0
            post(null, Result(false, 0, 0, "")) { show(it) }
        }

        /** The user's swipes: the word being typed stays as typed (when that result isn't stale), then [edit] */
        private fun swipe(edit: () -> Unit) {
            val asked = keys.ask()
            word = ""
            at = 0
            results += {
                if (keys.fresh(asked) && preedit.isNotEmpty()) {
                    editor.finishComposing()
                    preedit = ""
                }
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
     * #280: the cursor moved into "hello", then into "world" before the first reopen came back. The first is
     * stale and its region (2 before, 3 after) would take "world" at the new cursor: it is refused.
     */
    @Test
    fun aReopenReadBeforeTheCursorMovedAgainIsNotApplied() {
        val field = Field("hello world", 2)
        val editor = Editor(null, field.connection)
        editor.selectionChanged(2, 2, -1, -1) // he|llo world
        val first = editor.around()
        field.tap(8)
        editor.selectionChanged(8, 8, -1, -1) // hello wo|rld
        val second = editor.around()

        assertFalse(editor.unchanged(first))
        assertTrue(editor.unchanged(second))
        assertFalse(editor.composeRegion(2, 3, first.text(2, 3)))
        assertNull(field.region)
        assertTrue(editor.composeRegion(2, 3, second.text(2, 3)))
        assertEquals(6 until 11, field.region)
        assertEquals("hello world", field.text)
        // The app's own edit, with no update yet, makes a reopen read before it stale too.
        field.text = "hello world!"
        assertFalse(editor.unchanged(second))
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
        for (extract in listOf(true, false)) {
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
            // A field that can't say where its cursor is has no word reopened
            assertEquals(if (extract) 0 until 6 else null, field.region)
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
        for (extract in listOf(true, false)) {
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
        val field = Field("hello world", 11)
        val ime = Ime(field)
        field.tap(2)
        ime.swipeSpace(1)
        ime.settle()
        assertEquals(3, field.cursor)
        assertEquals("hello world", field.text)
    }
}
