package dev.sebb.sebtype.sync

import java.io.File
import java.io.IOException

/**
 * The conversions picked in 日本語 in the sync (#409): this phone's record, `mozc_learned.txt`, which Mozc keeps
 * in its folder, and the other devices' in `mozc_learned/<device>.txt` beside it, which Mozc learns as it starts
 * (core/src/mozc_learned.h).
 */
object MozcLearnedSync {
    const val FILE = "mozc_learned.txt"
    const val DIR = "mozc_learned"
    /** core's learned::kMaxBytes: a larger record isn't taken in, so it isn't downloaded. */
    const val MAX_BYTES = 1L shl 20

    /**
     * Uploads each of [files] with [put]. A server from before #409 refuses this phone's record (404): the
     * others still go up.
     */
    fun uploadAll(files: Map<String, ByteArray>, put: (String, ByteArray) -> Unit) {
        for((name, bytes) in files) {
            try {
                put(name, bytes)
            } catch(e: SyncHttpError) {
                if(name != FILE || e.code != 404) throw e
            }
        }
    }

    /**
     * Restarts Mozc so it learns the other devices' records, only while the keyboard is hidden: [stop] runs on
     * the thread keys run on, posted before any key of the next time it shows, so it never ends a word being
     * typed. Pending is kept in [flag], so it outlives a sync that fails after a download, and the process.
     * [shown] and [arrange] come from the main thread, [mark] from any.
     */
    class Replay(private val flag: File, private val stop: () -> Unit) {
        private var keyboardShown = false

        /** A record came in: Mozc learns it at its next restart. */
        fun mark() {
            flag.parentFile!!.mkdirs()
            if(!flag.exists() && !flag.createNewFile()) throw IOException("can't keep the restart for later")
        }

        fun shown(on: Boolean) {
            keyboardShown = on
            arrange()
        }

        /** Restarts Mozc if it is pending and the keyboard is hidden; else leaves it for the next hide. */
        fun arrange() {
            if(keyboardShown || !flag.exists()) return
            flag.delete() // first: a record marked after this is learned by this restart or the next one
            stop()
        }
    }
}
