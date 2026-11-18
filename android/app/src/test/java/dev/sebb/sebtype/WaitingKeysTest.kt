package dev.sebb.sebtype

import dev.sebb.sebtype.Layout.Code
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WaitingKeysTest {
    /** The keyboard around the queue: what reaches the field, in order, and the edits still waiting for the engine. */
    private class Keyboard {
        val field = StringBuilder()
        val shifts = ArrayList<Boolean>()
        var ready = true
        val engine = ArrayDeque<() -> Unit>()
        val q = WaitingKeys({ ready }, { field.append(it.text); shifts += it.userShift }, {})

        /** A key tapped: held, or typed at once */
        fun tap(text: String, userShift: Boolean = false, chineseStarting: Boolean = false, code: Code = Code.TEXT) {
            val key = WaitingKeys.Key(code, text, 1, 2, userShift)
            if (!q.hold(key, chineseStarting)) field.append(text)
        }

        /** An edit that puts [text] in once the engine answers (finishTyping) */
        fun edit(text: String) = q.switch { finish -> engine.addLast { finish { field.append(text) } } }

        /** Any other action that reaches the field (a chip, a swipe), shown as [text] */
        fun action(text: String) = q.run { field.append(text) }

        fun engineAnswers() = engine.removeFirst()()
    }

    /** #351: a search closes, Rime gets ready before the close's reset, then n is tapped: it waits for the reset. */
    @Test
    fun keyAfterReadyWaitsForPendingSwitch() {
        val k = Keyboard()
        k.edit("|")
        k.tap("n")
        assertEquals("", k.field.toString())
        k.engineAnswers()
        assertEquals("|n", k.field.toString())
    }

    /** #351: paste, a, paste, both pastes still waiting for the engine: x a x, not x x a. */
    @Test
    fun editsAndKeysKeepTheirOrder() {
        val k = Keyboard()
        k.edit("x")
        k.tap("a")
        k.edit("x")
        while (k.engine.isNotEmpty()) k.engineAnswers()
        assertEquals("xax", k.field.toString())
        k.tap("b")
        assertEquals("xaxb", k.field.toString())
    }

    /** #351: each key waiting replays with the Shift it was tapped with: H then i, not the last tap's for both. */
    @Test
    fun waitingKeysKeepTheirShift() {
        val k = Keyboard()
        k.edit("")
        k.tap("H", userShift = true)
        k.tap("i", userShift = false)
        k.engineAnswers()
        assertEquals(listOf(true, false), k.shifts)
    }

    /** #351: letters typed while Rime starts wait, with what follows them, and leave the reading they type. */
    @Test
    fun keysWaitForRimeInOrder() {
        val k = Keyboard()
        k.ready = false
        k.tap(" ", code = Code.SPACE, chineseStarting = true)
        for (ch in "ranh") k.tap("$ch", chineseStarting = true)
        k.tap("", code = Code.DELETE)
        assertEquals("ran", k.q.reading())
        k.q.drain()
        assertEquals(" ", k.field.toString())
        k.ready = true
        k.q.drain()
        assertEquals(" ranh", k.field.toString())
        // Rime ready, nothing waiting, no edit pending: keys go straight to it
        assertFalse(k.q.hold(WaitingKeys.Key(Code.TEXT, "n", 0, 0, false), chineseStarting = false))
    }

    /** #351: two pastes queued behind keys waiting for Rime, then a new field: neither lands, in either field. */
    @Test
    fun newFieldDropsQueuedEdits() {
        val k = Keyboard()
        k.ready = false
        k.tap("n", chineseStarting = true)
        k.edit("x")
        k.edit("y")
        k.q.cancel()
        k.ready = true
        k.q.drain()
        while (k.engine.isNotEmpty()) k.engineAnswers()
        assertEquals("", k.field.toString())
        assertFalse(k.q.hasKeys())
    }

    /** #351: a paste under way when the field changes lands nowhere, and starts nothing queued before the change. */
    @Test
    fun editUnderWayLandsNowhereAfterNewField() {
        val k = Keyboard()
        k.edit("x")
        k.edit("y")
        k.q.cancel()
        k.engineAnswers()
        assertEquals("", k.field.toString())
        assertTrue(k.engine.isEmpty())
        // The new field types at once
        k.tap("a")
        assertEquals("a", k.field.toString())
    }

    /** #351: 日本語, a paste pending: ka, Enter, then あ→ア: the chip waits for the keys, so か is committed, not カ. */
    @Test
    fun chipWaitsForKeysBeforeIt() {
        val k = Keyboard()
        k.edit("|")
        k.tap("k")
        k.tap("a")
        k.tap("\n", code = Code.ENTER)
        k.action("[ア]")
        k.engineAnswers()
        assertEquals("|ka\n[ア]", k.field.toString())
    }

    /** #351: English, a paste pending: a, then a Space swipe left: the cursor moves after a is typed. */
    @Test
    fun swipeWaitsForKeysBeforeIt() {
        val k = Keyboard()
        k.edit("x")
        k.tap("a")
        k.action("<")
        k.engineAnswers()
        assertEquals("xa<", k.field.toString())
        // Nothing waiting: an action runs at once
        k.action(">")
        assertEquals("xa<>", k.field.toString())
    }
}
