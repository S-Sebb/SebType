package dev.sebb.sebtype

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ActionRowTest {
    private val pinned = listOf(Action.EMOJI, Action.UNDO, Action.REDO, Action.CLIPBOARD, Action.INCOGNITO, Action.MODES)

    /** #430: Chinese mode puts 简/繁 second (right after ⋯) and fits all pinned shortcuts within the row width. */
    @Test
    fun chinesePutsTraditionalSecondAndFitsWidth() {
        val density = 2.625f
        for (dp in listOf(144f, 160f, 320f, 360f, 412f, 600f)) {
            val w = dp * density
            val slots = ActionRow.layout(w, density, pinned, traditional = false)
            assertEquals(listOf(ActionRow.All, ActionRow.Traditional) + pinned, slots.map { it.third })
            assertEquals(0f, slots.first().first, 1e-3f)
            assertTrue("$dp dp overflows: ${slots.last().second} > $w", slots.last().second <= w + 1e-3f)
            for (i in 1 until slots.size) {
                assertEquals(slots[i - 1].second, slots[i].first, 1e-3f)
                val slotW = slots[i].second - slots[i].first
                assertTrue(slotW > 0f)
                assertTrue("icon wider than slot at $dp dp", ActionRow.iconSize(slotW, density) <= slotW)
                assertTrue("glyph wider than slot at $dp dp", ActionRow.glyphSize(slotW, density) <= slotW)
            }
        }
    }

    /** #430: outside Chinese mode (traditional == null), the row keeps ⋯ followed directly by pinned shortcuts. */
    @Test
    fun nonChineseOmitsTraditional() {
        val density = 2.625f
        val slots = ActionRow.layout(360f * density, density, pinned, traditional = null)
        assertEquals(listOf(ActionRow.All) + pinned, slots.map { it.third })
    }
}
