package dev.sebb.sebtype.next

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ClipboardTest {
    private val hour = 3_600_000L
    private val now = 1_800_000_000_000L

    /**
     * The history today's app saved, oldest first, with an image (text null) among the texts: every clip is
     * read, newest first, the image too, and one that is neither text nor an image is left out alone.
     */
    @Test
    fun todaysHistoryWithAnImageIsKept() {
        val json = """[
            {"timestamp":${now - 3 * hour},"pinned":true,"text":"oldest, pinned","uri":null,"mimeTypes":["text/plain"]},
            {"timestamp":${now - 2 * hour},"pinned":false,"text":null,"uri":null,"mimeTypes":["image/png"],"backingFile":"0a1b.png","sizeMb":0.25},
            {"timestamp":${now - 1 * hour},"pinned":false,"text":null,"uri":null,"mimeTypes":[]},
            {"timestamp":$now,"pinned":false,"text":"newest","uri":null,"mimeTypes":["text/plain"]}
        ]"""
        val clips = Clipboard.decode(json, now)
        assertEquals(listOf("newest", null, "oldest, pinned"), clips.map { it.text })
        val image = clips[1]
        assertEquals("0a1b.png", image.file)
        assertEquals(listOf("image/png"), image.mimeTypes)
        assertEquals(0.25f, image.sizeMb)
        assertEquals(true, clips[2].pinned)
        // Saved again, it reads back the same, in today's order
        val again = Clipboard.decode(Clipboard.encode(clips), now)
        assertEquals(clips.map { listOf(it.text, it.file, it.pinned, it.timestamp) }, again.map { listOf(it.text, it.file, it.pinned, it.timestamp) })
    }

    /** Stage 4's own file (text and pinned only) still reads, as copied now. */
    @Test
    fun stage4HistoryReads() {
        val clips = Clipboard.decode("""[{"text":"b","pinned":false},{"text":"a","pinned":true}]""", now)
        assertEquals(listOf("a", "b"), clips.map { it.text })
        assertEquals(now, clips[0].timestamp)
        assertNull(clips[0].file)
    }

    /** Unpinned clips go after 72 hours, pinned ones stay; at most 25 unpinned, and 40 MB of their images. */
    @Test
    fun expiry() {
        val old = Clipboard.Clip("old", false, now - 73 * hour)
        val oldPinned = Clipboard.Clip("old pinned", true, now - 500 * hour)
        val recent = Clipboard.Clip("recent", false, now - 71 * hour)
        assertEquals(listOf(recent, oldPinned), Clipboard.pruned(listOf(recent, old, oldPinned), now) { null })

        val many = (0 until 30).map { Clipboard.Clip("t$it", false, now - it) }
        assertEquals(many.take(25), Clipboard.pruned(many, now) { null })

        val images = (0 until 3).map { Clipboard.Clip(null, false, now - it, "i$it.png", listOf("image/png"), 15f) }
        assertEquals(images.take(2), Clipboard.pruned(images, now) { it.sizeMb })
    }

    /** A search finds clips by their text, in any case, and images by their type. */
    @Test
    fun search() {
        val text = Clipboard.Clip("Meet at Kings Cross", false, now)
        val image = Clipboard.Clip(null, false, now, "a.png", listOf("image/png"))
        val clips = listOf(text, image)
        assertEquals(listOf(text), Clipboard.find(clips, "kings"))
        assertEquals(listOf(image), Clipboard.find(clips, "png"))
        assertEquals(emptyList<Clipboard.Clip>(), Clipboard.find(clips, " "))
    }
}
