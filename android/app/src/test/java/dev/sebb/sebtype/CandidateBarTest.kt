package dev.sebb.sebtype

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CandidateBarTest {
    private val available = 360f
    private val button = 45f

    /** #429: when all candidates fit in the bar, the expand arrow is hidden and candidates get the full width. */
    @Test
    fun expandHiddenWhenCandidatesFit() {
        for (extent in listOf(0f, 120f, available)) {
            val show = showExpandButton(slots = false, expanded = false, extent = extent, available = available)
            assertFalse("extent=$extent should not show expand", show)
            assertEquals(available, candidateViewport(available, show, button), 1e-4f)
        }
        // No candidates on a bar whose controls exceed its width still does not show expand
        assertFalse(showExpandButton(slots = false, expanded = false, extent = 0f, available = -10f))
    }

    /** #429: when candidates overflow the bar, the expand arrow shows and the viewport reserves room for it. */
    @Test
    fun expandShownWhenCandidatesOverflow() {
        val show = showExpandButton(slots = false, expanded = false, extent = available + 1f, available = available)
        assertTrue(show)
        assertEquals(available - button, candidateViewport(available, show, button), 1e-4f)
    }

    /** #429: while expanded, the collapse arrow stays shown even if all candidates fit, so the user can close it. */
    @Test
    fun collapseStaysShownWhileExpandedEvenWhenCandidatesFit() {
        for (extent in listOf(0f, 120f, available)) {
            val show = showExpandButton(slots = false, expanded = true, extent = extent, available = available)
            assertTrue("extent=$extent while expanded should show collapse", show)
            assertEquals(available - button, candidateViewport(available, show, button), 1e-4f)
        }
    }

    @Test
    fun slotsNeverShowExpand() {
        assertFalse(showExpandButton(slots = true, expanded = false, extent = available + 100f, available = available))
        assertFalse(showExpandButton(slots = true, expanded = true, extent = available, available = available))
    }

    /**
     * #454: three long English words keep inside their slots, past the dividers and the chip's padding, on the
     * narrowest common phone (360 dp, the › button taking 45) and a usual one, readable and still told apart.
     */
    @Test
    fun longWordsFitTheirSlots() {
        val measure = { s: String -> s.sumOf { NUNITO_18.getValue(it).toDouble() }.toFloat() }
        val words = listOf("authentication", "authentications", "\"authdntication\"")
        for (bar in listOf(360f, 411f)) {
            val slot = (bar - button) / 3
            val fitted = words.mapIndexed { i, word ->
                val (label, size) = fitSlot(word, slot - 26f, 18f, 11f, measure)
                val w = measure(label) * size / 18f
                val left = button + i * slot + slot / 2 - w / 2
                // Clear of the divider at the slot's left, the next one at its right, and the chip's padding
                assertTrue("$word at $bar dp: $left..${left + w} in slot ${button + i * slot}", left >= button + i * slot + 13f - 1e-3f)
                assertTrue("$word at $bar dp: $left..${left + w}", left + w <= button + (i + 1) * slot - 13f + 1e-3f)
                assertTrue(size in 11f..18f)
                label
            }
            assertEquals("$fitted", words.size, fitted.toSet().size)
        }
    }

    @Test
    fun shortWordsKeepFullSize() {
        assertEquals("the" to 18f, fitSlot("the", 80f, 18f, 11f) { it.length * 9f })
    }
}

/** Nunito ExtraBold's advances at 18 dp, from the font file, for the letters the tests use */
private val NUNITO_18 = mapOf('"' to 8.66f, 'a' to 10.03f, 'c' to 8.60f, 'd' to 10.98f, 'e' to 9.88f, 'h' to 10.71f, 'i' to 4.82f,
    'n' to 10.71f, 'o' to 10.60f, 's' to 8.86f, 't' to 7.27f, 'u' to 10.62f, '…' to 14.04f)
