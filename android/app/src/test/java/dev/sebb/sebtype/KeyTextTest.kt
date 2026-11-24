package dev.sebb.sebtype

import dev.sebb.sebtype.Layout.Code
import dev.sebb.sebtype.core.NativeCore.CHINESE
import dev.sebb.sebtype.core.NativeCore.ENGLISH
import dev.sebb.sebtype.core.NativeCore.JAPANESE
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
        val size = LETTER_DP * density * scale
        return letterSizes(qwerty, size, room) { width(it, size) } to room
    }

    private fun width(s: String, size: Float) = inks.getValue(s.single()) * size

    /** #283, #329: full-width docked keyboards, the owner's phone and landscape, draw every letter at 27.5 dp, W too. */
    @Test
    fun fullWidthKeyboardsDrawLargerLetters() {
        for (dp in listOf(411f, 800f)) {
            val (sizes, _) = drawn(dp, split = false)
            for ((letter, size) in sizes) assertEquals("$letter on a $dp dp keyboard", 27.5f * density, size, 1e-3f)
        }
    }

    /** #283, #329: split's, one-handed's and a 360 dp phone's keys draw every letter at one size, W within its keycap. */
    @Test
    fun narrowDockedKeysShareOneLetterSize() {
        for ((dp, split) in listOf(320f to true, 360f * Mode.ONE_HANDED_WIDTH to false, 360f to false)) {
            val (sizes, room) = drawn(dp, split)
            assertEquals("one size on a $dp dp keyboard (split $split): $sizes", 1, sizes.values.toSet().size)
            val size = sizes.getValue("w")
            assertTrue("W ${width("W", size)} px in $room px", width("W", size) <= room + 1e-3f)
        }
    }

    /** #531: with the number row over the letters, every other page keeps the keyboard's height, its last key's bottom too. */
    @Test
    fun pagesKeepTheNumberRowsHeight() {
        val rowHeight = 59.3f * density
        val tall = layout("numbers").rows + layout("letters").rows
        val fill = rowsHeight(tall)
        val height = keysHeight(tall, rowHeight, density)
        for (name in listOf("symbols", "symbols2", "digits")) {
            val rows = layout(name).rows
            val stretched = pageRowHeight(rows, fill, rowHeight)
            assertEquals(name, height, keysHeight(rows, stretched, density), 1e-3f)
            assertEquals(name, height, keyCells(rows, 1080f, stretched, density, false).maxOf { it.second.bottom }, 1e-3f)
        }
        // Without a number row the pages are as tall as the letters, at their own row height.
        assertEquals(rowHeight, pageRowHeight(layout("symbols").rows, 0f, rowHeight))
        assertEquals(rowHeight, pageRowHeight(tall, fill, rowHeight))
    }

    // --- #329: the owner's constraints: keys' places, touch areas and the keyboard's size as main's; keycaps grow ---

    private fun layout(name: String) = Layout.parse(name, File("src/main/assets/layouts/$name.json").readText(), "en")

    /** Main's cells before #329 (KeyboardView.layoutCells), kept here to compare against */
    private fun mainCells(rows: List<Layout.Row>, width: Float, rowHeight: Float, split: Boolean): List<Box> {
        val side = 2 * density
        val unit = (width - 2 * side) / 10f
        val half = 0.36f * (width - 2 * side) / 5f
        fun left(u: Float) = side + if (split) u * half else u * unit
        fun right(u: Float) = width - side - (10 - u) * half
        var y = 4.2f * density
        val out = ArrayList<Box>()
        for (row in rows) {
            val h = row.height * rowHeight
            var u = 0f
            for (key in row.keys) {
                val end = u + key.width
                if (key.code != Layout.Code.GAP) when {
                    !split || end <= 5 -> out += Box(left(u), y, left(end), y + h)
                    u >= 5 -> out += Box(right(u), y, right(end), y + h)
                    key.width <= 1 -> { out += Box(left(u), y, left(end), y + h); out += Box(right(u), y, right(end), y + h) }
                    else -> { out += Box(left(u), y, left(5f), y + h); out += Box(right(5f), y, right(end), y + h) }
                }
                u = end
            }
            y += h
        }
        return out
    }

    @Test
    fun keycapsGrowInsideTheViewWithoutTouching() {
        val four = 4 * 59.3f
        // name, keys' width in dp, height scale, split
        val keyboards = listOf(
            Triple("portrait", 411f, Mode.MIN_HEIGHT) to false, Triple("portrait", 411f, 1f) to false,
            Triple("portrait", 411f, Mode.MAX_HEIGHT) to false, Triple("landscape", 800f, 1f) to false,
            Triple("landscape", 800f, Mode.MAX_HEIGHT) to false,
            Triple("one-handed", 411f * Mode.ONE_HANDED_WIDTH, 1f) to false,
            Triple("split", 411f, 1f) to true, Triple("split, landscape", 800f, 1f) to true,
            Triple("floating", 411f * Mode.FLOATING_WIDTH, 1f) to false,
            // The tallest floating keyboard: four rows of two thirds of a 1200 dp window; the smallest
            Triple("floating, tallest", 411f * Mode.FLOATING_WIDTH, 1200f * 2 / 3 / four) to false,
            Triple("floating, landscape, tallest", 800f * Mode.FLOATING_WIDTH, Mode.FLOATING_MAX_HEIGHT_DP / four) to false,
            Triple("floating, smallest", Mode.FLOATING_MIN_WIDTH_DP, Mode.FLOATING_MIN_HEIGHT_DP / four) to false,
        )
        for ((k, split) in keyboards) for (numberRow in listOf(false, true)) {
            val (name, dp, scale) = k
            val what = "$name at $scale${if (numberRow) ", number row" else ""}"
            val rows = (if (numberRow) layout("numbers").rows else emptyList()) + layout("letters").rows
            val width = dp * density
            val rowHeight = 59.3f * density * scale
            val cells = keyCells(rows, width, rowHeight, density, split).map { it.second }
            assertEquals("cells of $what", mainCells(rows, width, rowHeight, split), cells)
            val height = keysHeight(rows, rowHeight, density)
            assertEquals("height of $what", 4.2f * density + rows.sumOf { it.height.toDouble() }.toFloat() * rowHeight, height, 1e-3f)
            val key = if (split) 0.36f * (width - 4 * density) / 5 else (width - 4 * density) / 10
            val faces = cells.map { keyFace(it, density, keyTextScale(scale, key / density)) }
            for (f in faces) {
                assertTrue("$f inside $width x $height, $what", f.left >= 0 && f.top >= 0 && f.right <= width && f.bottom <= height)
            }
            for (i in faces.indices) for (j in i + 1 until faces.size) {
                val (a, b) = faces[i] to faces[j]
                val overlap = a.left < b.right && b.left < a.right && a.top < b.bottom && b.top < a.bottom
                assertTrue("$a and $b overlap, $what", !overlap)
            }
        }
    }

    /** #329: at a docked height a keycap is today's, 2 dp wider and 8% taller around the same middle */
    @Test
    fun dockedKeycapsAreTwoDpWiderAndEightPercentTaller() {
        val cell = Box(100f, 50f, 100f + 40f * density, 50f + 59.3f * density)
        val face = keyFace(cell, density, 1f)
        val h = 59.3f * density * 0.83f
        assertEquals((40f - 3.5f + 2f) * density, face.right - face.left, 1e-3f)
        assertEquals(h * 1.08f, face.bottom - face.top, 1e-3f)
        assertEquals(50f + h / 2, (face.top + face.bottom) / 2, 1e-3f)
    }

    // --- #382: a letter key follows the finger until it lifts ---

    /**
     * The key typed for a finger put down at the first point, moved through the next ones and lifted at the last,
     * as KeyboardView's touch handling steps it: [slidTo] on every MOVE and on the UP.
     */
    private fun typed(path: List<Pair<Float, Float>>): String {
        val rows = layout("letters").rows
        val rowHeight = 59.3f * density
        val laid = keyCells(rows, 411 * density, rowHeight, density, false)
        val keys = laid.map { it.first }
        val boxes = laid.map { it.second }
        val height = keysHeight(rows, rowHeight, density)
        var key = keyAt(boxes, path[0].first, path[0].second, height)!!
        for ((x, y) in path.drop(1)) slidTo(keys, boxes, key, x, y, height, 8 * density)?.let { key = it }
        return keys[key].text
    }

    private fun box(text: String) = keyCells(layout("letters").rows, 411 * density, 59.3f * density, density, false)
        .first { it.first.text == text }.second

    @Test
    fun aLetterSlidOntoItsNeighbourTypesTheNeighbour() {
        val (q, w) = box("q") to box("w")
        val y = (q.top + q.bottom) / 2
        assertEquals("w", typed(listOf((q.left + q.right) / 2 to y, (w.left + w.right) / 2 to y)))
        // Back again: the key it is on when it lifts
        assertEquals("q", typed(listOf((q.left + q.right) / 2 to y, (w.left + w.right) / 2 to y, q.left + 2 to y)))
    }

    @Test
    fun aFingerMovingWithinItsKeyOrJustOverTheEdgeKeepsIt() {
        val q = box("q")
        val y = (q.top + q.bottom) / 2
        assertEquals("q", typed(listOf(q.left + 2 to y, q.right - 2 to y)))
        // Under today's 8 dp past the edge, the key stays (hysteresis)
        assertEquals("q", typed(listOf((q.left + q.right) / 2 to y, q.right + 7 * density to y)))
        assertEquals("w", typed(listOf((q.left + q.right) / 2 to y, q.right + 9 * density to y)))
    }

    /** Review of #390: the last MOVE short of the threshold, the UP past it: the letter it lifts on */
    @Test
    fun theLiftOffPointCounts() {
        val q = box("q")
        val y = (q.top + q.bottom) / 2
        assertEquals("w", typed(listOf((q.left + q.right) / 2 to y, q.right + 7 * density to y, q.right + 12 * density to y)))
    }

    @Test
    fun onlyLettersFollowTheFinger() {
        val rows = layout("letters").rows
        val laid = keyCells(rows, 411 * density, 59.3f * density, density, false)
        val space = laid.first { it.first.code == Layout.Code.SPACE }
        val shift = laid.first { it.first.code == Layout.Code.SHIFT }
        val z = laid.first { it.first.text == "z" }
        val far = 100 * density
        // Space and Delete swipe, Shift chords: they keep their key
        assertTrue(!slides(space.first, space.second, z.first, 0f, 0f, 0f))
        assertTrue(!slides(shift.first, shift.second, z.first, z.second.left + far, z.second.top, 8 * density))
        // A letter slid onto Space doesn't type a space
        assertTrue(!slides(z.first, z.second, space.first, space.second.left + 1, space.second.top + 1, 0f))
    }

    /** #526: the held globe's list picks the row the finger is on; back on the globe or away from the list, none. */
    @Test
    fun heldGlobeListCancels() {
        val rows = List(4) { Box(100f, 100f + it * 50f, 300f, 150f + it * 50f) } // 100..300 x 100..300
        val globe = Box(100f, 320f, 160f, 400f)
        assertEquals(0, listRow(rows, globe, 200f, 120f, 25f))
        assertEquals(3, listRow(rows, globe, 200f, 299f, 25f))
        assertEquals(3, listRow(rows, globe, 200f, 310f, 25f)) // just under it: slop
        assertEquals(-1, listRow(rows, globe, 130f, 350f, 25f)) // back on the globe
        assertEquals(-1, listRow(rows, globe, 200f, 40f, 25f)) // above the list
        assertEquals(-1, listRow(rows, globe, 400f, 180f, 25f)) // beside it, over other keys
        assertEquals(-1, listRow(rows, globe, 130f, 340f, 25f)) // the globe wins over the slop
    }

    @Test
    fun theGlobeListPicksTheLanguagesItShowed() {
        // By the rows it opened with, whatever changed since: the IME then skips a language turned off
        val shown = listOf(ENGLISH, CHINESE, JAPANESE)
        assertEquals(CHINESE, globePick(shown, 1))
        assertEquals(JAPANESE, globePick(shown, 2)) // never Other keyboards…, even with 中文 off since
        assertEquals(OTHER_KEYBOARDS, globePick(shown, 3))
        assertEquals(null, globePick(shown, 4))
    }

    @Test
    fun aSecondFingerClosesTheGlobeListUnchosen() {
        assertEquals(Roll.CLOSE, roll(Code.GLOBE, list = true)) // over a row or not, it picks nothing
        assertEquals(Roll.TYPE, roll(Code.GLOBE, list = false)) // a globe still held short taps as before
        assertEquals(Roll.TYPE, roll(Code.TEXT, list = false))
        assertEquals(Roll.KEEP, roll(Code.SHIFT, list = false))
    }
}
