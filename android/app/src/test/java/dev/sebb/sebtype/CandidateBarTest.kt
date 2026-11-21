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
}
