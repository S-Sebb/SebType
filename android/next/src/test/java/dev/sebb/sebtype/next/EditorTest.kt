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
}
