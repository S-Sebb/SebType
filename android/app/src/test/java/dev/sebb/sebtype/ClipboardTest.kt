package dev.sebb.sebtype

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.nio.file.Files

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

    /**
     * Stage 4's own file (text and pinned only, pinned first, then newest first) reads in its order, as
     * copied now; when the 25 unpinned are full, a new copy drops the oldest, in either file's history.
     */
    @Test
    fun stage4HistoryKeepsItsOrder() {
        val texts = (25 downTo 1).map { "t$it" } // newest (t25) first
        val stage4 = JSONArray(listOf(JSONObject().put("text", "pin").put("pinned", true)) +
            texts.map { JSONObject().put("text", it).put("pinned", false) }).toString()
        val clips = Clipboard.decode(stage4, now)
        assertEquals(listOf("pin") + texts, clips.map { it.text })
        assertEquals(now, clips[1].timestamp)
        assertNull(clips[1].file)
        assertEquals(listOf("pin", "new") + texts.dropLast(1),
            Clipboard.capped(listOf(Clipboard.Clip("new", false, now)) + clips).map { it.text })

        // Today's file of the same clips, oldest first, reads newest first and drops the same one
        val todays = Clipboard.decode(Clipboard.encode(clips), now)
        assertEquals(listOf("pin") + texts, todays.map { it.text })
        assertEquals(listOf("pin", "new") + texts.dropLast(1),
            Clipboard.capped(listOf(Clipboard.Clip("new", false, now)) + todays).map { it.text })
    }

    /**
     * An image copied in while a text's save waits in the queue: that save, whose list of images doesn't have it,
     * leaves it; the save that shows it keeps it; an image dropped (history cleared meanwhile) goes.
     */
    @Test
    fun imageBeingAddedSurvivesAnEarlierSave() {
        val dir = Files.createTempDirectory("clips").toFile()
        try {
            val images = Clipboard.Images(dir)
            fun write(name: String) = File(dir, name).apply { writeText("x") }
            val old = write("old.png")
            images.adding("new.png")
            val new = write("new.png")
            val thumb = write("new.png.thumb.jpg")
            images.saved(emptySet()) // the text's save, queued before the image was in the history
            assertTrue(new.exists() && thumb.exists())
            assertFalse(old.exists())
            images.saved(setOf("new.png", "new.png.thumb.jpg"))
            images.added("new.png")
            images.saved(setOf("new.png", "new.png.thumb.jpg"))
            assertTrue(new.exists())

            images.adding("dropped.png")
            val dropped = write("dropped.png")
            images.added("dropped.png")
            assertFalse(dropped.exists())
            assertTrue(new.exists())
        } finally {
            dir.deleteRecursively()
        }
    }

    /**
     * The same image copied, the history cleared, then copied again: the second copy is saved before the
     * first's is dropped, and the dropped one mustn't delete the file the history now shows.
     */
    @Test
    fun droppedCopyLeavesTheSameImageCopiedAgain() {
        val dir = Files.createTempDirectory("clips").toFile()
        try {
            val images = Clipboard.Images(dir)
            images.adding("a.png")
            images.adding("a.png")
            val image = File(dir, "a.png").apply { writeText("x") }
            images.saved(setOf("a.png", "a.png.thumb.jpg")) // the second copy's history
            images.added("a.png")
            images.added("a.png") // the first copy, dropped
            assertTrue(image.exists())
            images.saved(emptySet())
            assertFalse(image.exists())
        } finally {
            dir.deleteRecursively()
        }
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
