package dev.sebb.sebtype.sync

import java.io.ByteArrayOutputStream
import java.io.File
import java.io.IOException
import java.io.InputStream

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
    /** Every device ID this Mozc folder's record went up under (sebtype_sync.py's OWN_LEARNED). */
    const val OWN = "mozc_learned.own"

    /** One changes when Rime's installation is made anew: the record under an older one is this phone's own,
     *  never another device's to learn (#415 review). */
    fun ownIds(mozcDir: File): Set<String> =
        File(mozcDir, OWN).takeIf { it.isFile }?.readText()?.split(Regex("\\s+"))?.filter { it.isNotEmpty() }?.toSet().orEmpty()

    /** Keeps [id] among [ownIds], before the record goes up under it. */
    fun keepOwnId(mozcDir: File, id: String) {
        val ids = ownIds(mozcDir)
        if(id !in ids) File(mozcDir, OWN).writeText((ids + id).sorted().joinToString("") { "$it\n" })
    }

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

    /** All of [input], or null past [max] bytes, read no further: a server can send more than its list said. */
    fun readAtMost(input: InputStream, max: Long = MAX_BYTES): ByteArray? {
        val out = ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while(true) {
            val n = input.read(buffer, 0, minOf(buffer.size.toLong(), max + 1 - out.size()).toInt())
            if(n < 0) return out.toByteArray()
            out.write(buffer, 0, n)
            if(out.size() > max) return null
        }
    }

    /**
     * Restarts Mozc so it learns the other devices' records, only while the keyboard is hidden. [shown] and
     * [arrange] run through [post], on the thread keys run on, where [stop] runs too: a hide's restart lands
     * before any key of the next show, so it never ends a word being typed, and no file is touched on the main
     * thread. Pending is kept in [flag], so it outlives a sync that fails after a download, and the process.
     * [mark] comes from the sync's thread.
     */
    class Replay(private val flag: Lazy<File>, private val post: (() -> Unit) -> Unit, private val stop: () -> Unit) {
        private var keyboardShown = false  // on the keys' thread

        /** A record came in: Mozc learns it at its next restart. */
        fun mark() {
            val flag = flag.value
            flag.parentFile!!.mkdirs()
            if(!flag.exists() && !flag.createNewFile()) throw IOException("can't keep the restart for later")
        }

        fun shown(on: Boolean) = post {
            keyboardShown = on
            restartIfPending()
        }

        /** Restarts Mozc if it is pending and the keyboard is hidden; else leaves it for the next hide. */
        fun arrange() = post { restartIfPending() }

        private fun restartIfPending() {
            if(keyboardShown || !flag.value.exists()) return
            flag.value.delete() // first: a record marked after this is learned by this restart or the next one
            stop()
        }
    }
}
