package dev.sebb.sebtype.next

import android.view.inputmethod.InputConnection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy

class EditorTest {
    /**
     * A text field as its InputConnection shows it: the text, the cursor and the composing region. Each change
     * sends a selection update, which the keyboard hears of later ([updates]).
     */
    private class Field(var text: String, var cursor: Int) {
        var region: IntRange? = null
        /** Updates sent and not yet heard of: the selection's start and end, the composing text's start and end */
        val updates = ArrayDeque<IntArray>()
        private fun changed() {
            updates += intArrayOf(cursor, cursor, region?.first ?: -1, region?.let { it.last + 1 } ?: -1)
        }

        /** The user puts the cursor at [at]; the composing text stays marked, as an EditText keeps it. */
        fun tap(at: Int) {
            cursor = at
            changed()
        }

        private fun replace(with: String, compose: Boolean) {
            val r = region ?: (cursor until cursor)
            text = text.substring(0, r.first) + with + text.substring(r.last + 1)
            cursor = r.first + with.length
            region = if (compose && with.isNotEmpty()) r.first until cursor else null
            changed()
        }

        val connection = Proxy.newProxyInstance(InputConnection::class.java.classLoader, arrayOf(InputConnection::class.java)) { _, method, args ->
            when (method.name) {
                "getTextBeforeCursor" -> text.substring(maxOf(0, cursor - args[0] as Int), cursor)
                "getTextAfterCursor" -> text.substring(cursor, minOf(text.length, cursor + args[0] as Int))
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
     * where the field is then.
     */
    private class Ime(val field: Field) {
        val editor = Editor(null, field.connection)
        private val keys = Keys()
        private val results = ArrayDeque<() -> Unit>()
        private var preedit = ""
        // The engine thread's word and its cursor in it
        private var word = ""
        private var at = 0

        /** The field's text from [before] to [after] the cursor made the word ([recompose]), then [word] composed */
        class Result(val recompose: Boolean, val before: Int, val after: Int, val word: String)

        private fun post(key: Keys.Key?, result: Result, show: (Result) -> Unit) {
            val asked = keys.ask()
            results += {
                if (keys.fresh(asked)) show(result)
                key?.done()
            }
        }

        private fun show(r: Result, around: Editor.Around? = null) {
            if (r.recompose && !editor.composeRegion(r.before, r.after, around?.text(r.before, r.after))) return context()
            editor.compose(r.word)
            preedit = r.word
        }

        /** English's read of the field: the word at the cursor reopened */
        private fun context(): Unit = keys.reread {
            val around = editor.around()
            val b = around.before.takeLastWhile { it.isLetter() }.length
            val a = around.after.takeWhile { it.isLetter() }.length
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

        /** The engine's state with nothing typed (READY): its empty preedit goes into the field */
        fun ready() {
            word = ""
            at = 0
            post(null, Result(false, 0, 0, "")) { show(it) }
        }

        /** What SebTypeIme.onUpdateSelection does with each update */
        fun updates() {
            while (field.updates.isNotEmpty()) {
                val (start, end, candidatesStart, candidatesEnd) = field.updates.removeFirst()
                val external = editor.selectionChanged(start, end, candidatesStart, candidatesEnd)
                if (external && preedit.isNotEmpty()) editor.finishComposing()
                if (external) context()
            }
        }

        /**
         * Results and updates, until both are done. The results already queued come first: the update for a
         * write comes from the app, after the results posted on the keyboard's thread behind it.
         */
        fun settle() {
            while (field.updates.isNotEmpty() || results.isNotEmpty()) {
                while (results.isNotEmpty()) results.removeFirst()()
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
        field.cursor = 8
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
}
