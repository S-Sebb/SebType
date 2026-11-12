package dev.sebb.sebtype.chinese

import android.content.Context
import org.futo.inputmethod.latin.utils.ZipFileHelper
import java.io.File
import java.io.FilterInputStream
import java.io.InputStream
import org.futo.inputmethod.engine.general.ChineseIME

/**
 * SebType's Chinese data: rime-ice's schemas and Lua with 白霜 (rime-frost) core's dictionary and grammar
 * (both GPL-3.0), compiled by data/rime/build.sh and bundled in the APK's assets/rime/. It is
 * installed into Rime's shared dir whenever the bundled version differs from the installed one, so
 * Chinese works right after install and after every update with no import step. It comes compiled, so
 * Rime only checks it. Learned words stay in the user dir.
 */
object RimeIceBundle {
    const val SCHEMA = "rime_ice"

    // Self-test after deploy: plain abbreviated pinyin, no Lua or learned words involved.
    const val SELF_TEST_INPUT = "ranh"
    const val SELF_TEST_WORD = "然后"

    private const val INSTALLED_VERSION = ".sebtype-bundle-version"

    private const val ZIP = "rime/rime-data.zip"

    fun bundledVersion(context: Context) =
        context.assets.open("rime/bundle-version").bufferedReader().use { it.readText().trim() }

    private fun marker(context: Context) = File(ChineseIME.getShared(context), INSTALLED_VERSION)

    fun isInstalled(context: Context) =
        marker(context).let { it.isFile && it.readText() == bundledVersion(context) }

    /** Makes the next [isInstalled] false, so the bundle is installed again from scratch. */
    fun forget(context: Context) {
        marker(context).delete()
    }

    /** Installs the bundled data; [onProgress] gets the percentage of the zip extracted so far. */
    fun install(context: Context, onProgress: (Int) -> Unit = {}) {
        val shared = ChineseIME.getShared(context)
        shared.deleteRecursively()
        // Stored uncompressed in the APK (noCompress), so its asset length is the zip's size.
        val size = context.assets.openFd(ZIP).use { it.length }
        context.assets.open(ZIP).use { ZipFileHelper.extract(Progress(it, size, onProgress), shared) }
        restoreSourceTimes(shared)
        // Rime's own compiled copies from the previous version would be used instead of the bundled ones.
        File(ChineseIME.getUser(context), "build").deleteRecursively()
        // Written last, so an interrupted install is redone.
        marker(context).writeText(bundledVersion(context))
    }

    /**
     * Rime keeps a compiled file only while its sources have the modification times recorded in it
     * (`__build_info/timestamps`). Extracting sets them to now, so Rime would recompile the bundled
     * schemas and their prisms on the phone; this puts the recorded times back.
     */
    private fun restoreSourceTimes(shared: File) {
        val timestamp = Regex("""^    ([\w.]+): (\d+)$""")
        File(shared, "build").listFiles { f -> f.name.endsWith(".yaml") }?.forEach { compiled ->
            var inTimestamps = false
            compiled.forEachLine { line ->
                if(line == "  timestamps:") inTimestamps = true
                else if(inTimestamps) {
                    val (name, seconds) = timestamp.find(line)?.destructured ?: run { inTimestamps = false; return@forEachLine }
                    // Mid-second: Rime reads a file's time through the clocks' current difference,
                    // which can round an exact second down to the one before.
                    if(seconds != "0") File(shared, "$name.yaml").setLastModified(seconds.toLong() * 1000 + 500)
                }
            }
        }
    }

    private class Progress(input: InputStream, val size: Long, val onProgress: (Int) -> Unit) : FilterInputStream(input) {
        private var read = 0L
        private var percent = -1

        override fun read(b: ByteArray, off: Int, len: Int) = super.read(b, off, len).also { count(it) }
        override fun read() = super.read().also { if(it >= 0) count(1) }

        private fun count(n: Int) {
            if(n <= 0) return
            read += n
            val now = (read * 100 / size).toInt().coerceAtMost(100)
            if(now != percent) { percent = now; onProgress(now) }
        }
    }
}
