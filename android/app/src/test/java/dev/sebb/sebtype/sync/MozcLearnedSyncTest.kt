package dev.sebb.sebtype.sync

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class MozcLearnedSyncTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun flag() = File(tmp.root, "sync/mozc-restart")

    /** A sync that brings a record while the keyboard is up doesn't stop Mozc until the keyboard hides (#416 review). */
    @Test
    fun noRestartWhileTheKeyboardIsShown() {
        var stops = 0
        val replay = MozcLearnedSync.Replay(flag()) { stops++ }
        replay.shown(true)
        replay.mark()
        replay.arrange() // the sync's end, while typing
        assertEquals(0, stops)
        replay.shown(true) // shown again: still not
        assertEquals(0, stops)
        replay.shown(false)
        assertEquals(1, stops)
        replay.shown(false) // nothing pending any more
        replay.arrange()
        assertEquals(1, stops)
    }

    /** A record saved before a later download failed still restarts Mozc: the next sync's end, with nothing new, or
     *  the next hide, even in a new process (#416 review). */
    @Test
    fun aRestartPendingOutlivesAFailedSync() {
        var stops = 0
        MozcLearnedSync.Replay(flag()) { stops++ }.mark() // the sync then failed, before arranging it
        val next = MozcLearnedSync.Replay(flag()) { stops++ }
        next.arrange()
        assertEquals(1, stops)
        next.arrange()
        assertEquals(1, stops)
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
