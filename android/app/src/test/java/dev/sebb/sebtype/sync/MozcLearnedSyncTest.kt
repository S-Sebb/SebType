package dev.sebb.sebtype.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class MozcLearnedSyncTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun flag() = File(tmp.root, "sync/mozc-restart")
    // The keys' thread runs what is posted in order: here at once.
    private fun replay(stop: () -> Unit) = MozcLearnedSync.Replay(lazy { flag() }, { it() }, stop)

    /** A sync that brings a record while the keyboard is up doesn't stop Mozc until the keyboard hides (#416 review). */
    @Test
    fun noRestartWhileTheKeyboardIsShown() {
        var stops = 0
        val keys = replay { stops++ }
        keys.shown(true)
        keys.mark()
        keys.arrange() // the sync's end, while typing
        assertEquals(0, stops)
        keys.shown(true) // shown again: still not
        assertEquals(0, stops)
        keys.shown(false)
        assertEquals(1, stops)
        keys.shown(false) // nothing pending any more
        keys.arrange()
        assertEquals(1, stops)
    }

    /** A record saved before a later download failed still restarts Mozc: the next sync's end, with nothing new, or
     *  the next hide, even in a new process (#416 review). */
    @Test
    fun aRestartPendingOutlivesAFailedSync() {
        var stops = 0
        replay { stops++ }.mark() // the sync then failed, before arranging it
        val next = replay { stops++ }
        next.arrange()
        assertEquals(1, stops)
        next.arrange()
        assertEquals(1, stops)
    }

    /** A record larger than the server's list said is read no further than the limit, and not taken (#416 review). */
    @Test
    fun aRecordPastTheLimitIsNotRead() {
        val read = mutableListOf<Int>()
        fun stream(size: Int) = object : java.io.InputStream() {
            var left = size
            override fun read() = if(left-- > 0) 1 else -1
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                if(left <= 0) return -1
                val n = minOf(len, left)
                left -= n
                read += n
                return n
            }
        }
        assertEquals(10, MozcLearnedSync.readAtMost(stream(10), 10)!!.size)
        read.clear()
        assertNull(MozcLearnedSync.readAtMost(stream(1_000_000), 10))
        assertEquals(11, read.sum())
    }

    /** A server from before #409 refuses the phone's record: the files after it still go up; any other refusal
     *  fails the sync (#416 review). */
    @Test
    fun anOlderServerRefusingTheRecordSyncsTheRest() {
        val sent = mutableListOf<String>()
        val files = linkedMapOf(
            MozcLearnedSync.FILE to byteArrayOf(1), "mozc_dictionary.txt" to byteArrayOf(2), "userdictionary.json" to byteArrayOf(3),
        )
        MozcLearnedSync.uploadAll(files) { name, _ -> if(name == MozcLearnedSync.FILE) throw SyncHttpError(404) else sent += name }
        assertEquals(listOf("mozc_dictionary.txt", "userdictionary.json"), sent)
        assertThrows(SyncHttpError::class.java) {
            MozcLearnedSync.uploadAll(files) { name, _ -> if(name == "mozc_dictionary.txt") throw SyncHttpError(404) }
        }
        assertThrows(SyncHttpError::class.java) {
            MozcLearnedSync.uploadAll(files) { name, _ -> if(name == MozcLearnedSync.FILE) throw SyncHttpError(500) }
        }
    }
}
