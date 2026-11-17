package dev.sebb.sebtype.next

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class KeyTextTest {
    /** #283: every docked keyboard keeps today's text sizes (the screens #267 matched to today's app). */
    @Test
    fun dockedKeyboardsKeepTodaysText() {
        for (height in listOf(Mode.MIN_HEIGHT, 1f, Mode.MAX_HEIGHT)) {
            // Standard on a 360 dp phone, split's halves on a 320 dp one
            for (keyWidth in listOf(35.6f, 22.7f)) assertEquals(1f, keyTextScale(height, keyWidth))
        }
    }

    /** #283: the floating keyboard resized smaller than any docked one shrinks its text with its keys. */
    @Test
    fun smallFloatingKeysShrinkTheirText() {
        assertEquals(0.5f, keyTextScale(0.4f, 35.6f), 1e-6f)
        assertTrue(keyTextScale(1f, 14.4f) < 0.7f) // 144 dp wide
    }
}
