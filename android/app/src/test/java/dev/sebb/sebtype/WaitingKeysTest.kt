package dev.sebb.sebtype

import dev.sebb.sebtype.Layout.Code
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WaitingKeysTest {
    private fun texts(keys: List<WaitingKeys.Key>) = keys.map { it.text }

    /** #351: a search closes, Rime gets ready before the close's reset, then n is tapped: it waits for the reset. */
    @Test
    fun keyAfterReadyWaitsForPendingSwitch() {
        val q = WaitingKeys()
        q.switchStarted()
        assertTrue(q.hold(Code.TEXT, "n", 10, 20, chineseStarting = false))
        assertTrue(q.take(ready = true).isEmpty())
        q.switchDone()
        val fed = q.take(ready = true)
        assertEquals(listOf("n"), texts(fed))
        assertEquals(10, fed[0].x)
        assertTrue(q.isEmpty())
    }

    /** #351: letters typed while Rime starts wait, with what follows them, and leave the reading they type. */
    @Test
    fun keysWaitForRimeInOrder() {
        val q = WaitingKeys()
        assertFalse(q.hold(Code.SPACE, " ", 0, 0, chineseStarting = true))
        for (ch in "ranh") assertTrue(q.hold(Code.TEXT, "$ch", 0, 0, chineseStarting = true))
        assertTrue(q.hold(Code.DELETE, "", 0, 0, chineseStarting = false))
        assertEquals("ran", q.reading())
        assertTrue(q.take(ready = false).isEmpty())
        assertEquals(listOf("r", "a", "n", "h", ""), texts(q.take(ready = true)))
        // Rime ready, nothing waiting, no switch: keys go straight to it
        assertFalse(q.hold(Code.TEXT, "n", 0, 0, chineseStarting = false))
    }
}
