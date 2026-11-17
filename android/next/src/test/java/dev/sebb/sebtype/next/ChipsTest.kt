package dev.sebb.sebtype.next

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ChipsTest {
    @Test
    fun chipsShowInTheAnswersOrder() {
        val chips = Chips<String>()
        val answer = chips.start(2)
        assertEquals(listOf("b"), chips.inflated(answer, 1, "b"))
        assertEquals(listOf("a", "b"), chips.inflated(answer, 0, "a"))
    }

    /** #283: a chip that inflates after its field was left, or after a newer answer, never shows. */
    @Test
    fun aLeftFieldsChipsDontComeBack() {
        val chips = Chips<String>()
        val old = chips.start(2)
        chips.start(0) // the field is left
        assertNull(chips.inflated(old, 0, "old login"))
        val new = chips.start(1)
        assertNull(chips.inflated(old, 1, "old card"))
        assertEquals(listOf("new login"), chips.inflated(new, 0, "new login"))
    }
}
