package dev.sebb.sebtype.next

import android.view.inputmethod.InputConnection
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.lang.reflect.Proxy

class EditorTest {
    /** A text field as its InputConnection shows it: the text, the cursor and the composing region. */
    private class Field(var text: String, var cursor: Int) {
        var region: IntRange? = null
        val connection = Proxy.newProxyInstance(InputConnection::class.java.classLoader, arrayOf(InputConnection::class.java)) { _, method, args ->
            when (method.name) {
                "getTextBeforeCursor" -> text.substring(maxOf(0, cursor - args[0] as Int), cursor)
                "getTextAfterCursor" -> text.substring(cursor, minOf(text.length, cursor + args[0] as Int))
                "setComposingRegion" -> true.also { region = (args[0] as Int) until (args[1] as Int) }
                "finishComposingText" -> true.also { region = null }
                else -> if (method.returnType == Boolean::class.javaPrimitiveType) true else null
            }
        } as InputConnection
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
     * The engine thread's queue as the IME uses it: results come back in order, each written where the field's
     * cursor is when it comes; a key's result types its letter there.
     */
    private class Engine(val field: Field, val editor: Editor) {
        val keys = Keys()
        val results = ArrayDeque<() -> Unit>()
        var reads = 0
        fun post(key: Keys.Key? = null, show: () -> Unit) {
            val asked = keys.ask()
            results += {
                if (keys.fresh(asked)) show()
                key?.done()
            }
        }
        fun key(c: Char) = keys.type { key ->
            post(key) { field.text = field.text.substring(0, field.cursor) + c + field.text.substring(field.cursor); field.cursor++ }
        }
        fun move(to: Int) {
            field.cursor = to
            editor.selectionChanged(to, to, -1, -1)
            keys.reread { post { reads++ } }
        }
        fun deliver() { while (results.isNotEmpty()) results.removeFirst()() }
    }

    /**
     * #280: x typed at he|llo, the cursor moved to hello wo|rld and y typed there, all before x's result came.
     * x's result, asked for at he|llo, would write over "world"; it is dropped, and no key is lost: x and y
     * go in at the cursor in the order typed, as they do in today's app when its text reaches the app after
     * the tap.
     */
    @Test
    fun keysTypedAroundACursorMoveAreEachTypedOnce() {
        val field = Field("hello world", 2)
        val editor = Editor(null, field.connection)
        editor.selectionChanged(2, 2, -1, -1)
        val engine = Engine(field, editor)
        engine.key('x')
        engine.move(8)
        engine.key('y')
        engine.deliver()
        assertEquals("hello woxyrld", field.text)
    }

    /** #280: a result for no key (a READY strip, which writes the empty preedit) asked for before a move is dropped. */
    @Test
    fun aReadyStripAskedBeforeTheCursorMovedIsDropped() {
        val field = Field("hello world", 5)
        val editor = Editor(null, field.connection)
        editor.selectionChanged(5, 5, -1, -1)
        val engine = Engine(field, editor)
        engine.post { field.text = "" }
        engine.move(11)
        engine.deliver()
        assertEquals("hello world", field.text)
        assertEquals(1, engine.reads)
    }
}
