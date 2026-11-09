package org.futo.inputmethod.engine.general

import android.content.Context
import org.futo.inputmethod.latin.utils.ZipFileHelper
import java.io.File

/**
 * SebType's Chinese data: rime-ice's own release zip (GPL-3.0, unmodified, with its prebuilt build/),
 * bundled in the APK's assets/rime/ by sebtype/fetch-rime-ice.sh. It is installed into Rime's shared
 * dir whenever the bundled version differs from the installed one, so Chinese works right after install
 * and after every update with no import step. Learned words stay in the user dir.
 */
object RimeIceBundle {
    const val SCHEMA = "rime_ice"

    // Self-test after deploy: plain abbreviated pinyin, no Lua or learned words involved.
    const val SELF_TEST_INPUT = "ranh"
    const val SELF_TEST_WORD = "然后"

    private const val INSTALLED_VERSION = ".sebtype-bundle-version"

    private fun bundledVersion(context: Context) =
        context.assets.open("rime/bundle-version").bufferedReader().use { it.readText().trim() }

    private fun marker(context: Context) = File(ChineseIME.getShared(context), INSTALLED_VERSION)

    fun isInstalled(context: Context) =
        marker(context).let { it.isFile && it.readText() == bundledVersion(context) }

    /** Makes the next [isInstalled] false, so the bundle is installed again from scratch. */
    fun forget(context: Context) {
        marker(context).delete()
    }

    fun install(context: Context) {
        val shared = ChineseIME.getShared(context)
        shared.deleteRecursively()
        context.assets.open("rime/rime-ice.zip").use { ZipFileHelper.extract(it, shared) }
        restoreSourceTimes(shared)
        // Rime's own compiled copies from the previous version would be rebuilt on the phone (about a
        // minute) instead of using the bundled prebuilt ones.
        File(ChineseIME.getUser(context), "build").deleteRecursively()
        // Written last, so an interrupted install is redone.
        marker(context).writeText(bundledVersion(context))
    }

    /**
     * Rime keeps a compiled file only while its sources have the modification times recorded in it
     * (`__build_info/timestamps`). Extracting sets them to now, so Rime would rebuild all of rime-ice's
     * prebuilt build/ on the phone (the English prism alone takes about 25 s); this puts the recorded
     * times back. The files themselves stay as rime-ice ships them.
     */
    private fun restoreSourceTimes(shared: File) {
        val timestamp = Regex("""^    ([\w.]+): (\d+)$""")
        File(shared, "build").listFiles { f -> f.name.endsWith(".yaml") }?.forEach { compiled ->
            var inTimestamps = false
            compiled.forEachLine { line ->
                if(line == "  timestamps:") inTimestamps = true
                else if(inTimestamps) {
                    val (name, seconds) = timestamp.find(line)?.destructured ?: run { inTimestamps = false; return@forEachLine }
                    if(seconds != "0") File(shared, "$name.yaml").setLastModified(seconds.toLong() * 1000)
                }
            }
        }
    }
}
