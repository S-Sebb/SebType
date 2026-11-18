package dev.sebb.sebtype

import java.io.File
import java.nio.ByteBuffer
import kotlin.math.roundToInt
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

    /** The keys' font's letters' ink widths in ems, as the view measures them (Paint.getTextBounds) */
    private val inks: Map<Char, Float> = run {
        val b = ByteBuffer.wrap(File("../app/src/main/res/font/sebtype_nunito_extrabold.ttf").readBytes())
        val tables = (0 until b.getShort(4)).associate { i ->
            val at = 12 + 16 * i
            String(ByteArray(4) { b.get(at + it) }) to b.getInt(at + 8)
        }
        val em = b.getShort(tables.getValue("head") + 18).toFloat()
        // cmap's Windows Unicode subtable, format 4: segments of characters to glyphs
        val cmap = tables.getValue("cmap")
        val sub = cmap + (0 until b.getShort(cmap + 2)).map { cmap + 4 + 8 * it }
            .first { b.getShort(it).toInt() == 3 && b.getShort(it + 2).toInt() == 1 }.let { b.getInt(it + 4) }
        val segs = (b.getShort(sub + 6).toInt() and 0xffff) / 2
        val ends = sub + 14
        val starts = ends + 2 * segs + 2
        val deltas = starts + 2 * segs
        val offsets = deltas + 2 * segs
        fun u16(at: Int) = b.getShort(at).toInt() and 0xffff
        ('A'..'Z').plus('a'..'z').associateWith { c ->
            val i = (0 until segs).first { u16(ends + 2 * it) >= c.code }
            val offset = u16(offsets + 2 * i)
            val glyph = if (offset == 0) (c.code + u16(deltas + 2 * i)) and 0xffff
            else (u16(offsets + 2 * i + offset + 2 * (c.code - u16(starts + 2 * i))) + u16(deltas + 2 * i)) and 0xffff
            // The glyph's bounds: loca gives where it starts in glyf, whose header has xMin and xMax
            val loca = tables.getValue("loca")
            val start = tables.getValue("glyf") +
                if (b.getShort(tables.getValue("head") + 50).toInt() == 0) 2 * u16(loca + 2 * glyph) else b.getInt(loca + 4 * glyph)
            (b.getShort(start + 6) - b.getShort(start + 2)) / em
        }
    }
    private val qwerty = "qwertyuiopasdfghjklzxcvbnm".map { it.toString() }
    private val density = 2.625f // 420 dpi, the owner's phone and guide35

    /** The letters' sizes drawn on a docked keyboard [dp] wide, its keys [split] or not, and the room in a key */
    private fun drawn(dp: Float, split: Boolean): Pair<Map<String, Float>, Float> {
        val usable = (dp - 2 * 2) * density // KeyboardView's sidePadding on each side
        val key = if (split) 0.36f * usable / 5 else usable / 10
        val scale = keyTextScale(1f, key / density)
        val px = maxOf(1, (2 * density).roundToInt()) // Picnic.pixel
        val keyPx = maxOf(1, (px * scale).roundToInt()).toFloat()
        val room = keycapRoom(key, density, scale, keyPx)
        val size = 25 * density * scale
        return letterSizes(qwerty, size, room) { width(it, size) } to room
    }

    private fun width(s: String, size: Float) = inks.getValue(s.single()) * size

    /** #283: full-width docked keyboards, portrait and landscape, draw every letter at today's 25 dp, W too. */
    @Test
    fun fullWidthKeyboardsDrawTodaysLetters() {
        for (dp in listOf(360f, 411f, 800f)) {
            val (sizes, _) = drawn(dp, split = false)
            for ((letter, size) in sizes) assertEquals("$letter on a $dp dp keyboard", 25 * density, size, 1e-3f)
        }
    }

    /** #283, #329: split's and one-handed's keys draw every letter at one size, W within its keycap. */
    @Test
    fun narrowDockedKeysShareOneLetterSize() {
        for ((dp, split) in listOf(320f to true, 360f * Mode.ONE_HANDED_WIDTH to false)) {
            val (sizes, room) = drawn(dp, split)
            assertEquals("one size on a $dp dp keyboard (split $split): $sizes", 1, sizes.values.toSet().size)
            val size = sizes.getValue("w")
            assertTrue("W ${width("W", size)} px in $room px", width("W", size) <= room + 1e-3f)
        }
    }
}
