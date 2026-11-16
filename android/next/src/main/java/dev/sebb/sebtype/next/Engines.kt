package dev.sebb.sebtype.next

import android.content.Context
import android.content.res.Configuration
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import dev.sebb.sebtype.core.NativeCore
import dev.sebb.sebtype.core.NativeCore.CHINESE
import dev.sebb.sebtype.core.NativeCore.JAPANESE
import java.io.File
import java.io.IOException
import java.util.Locale
import java.util.concurrent.Executors
import java.util.zip.ZipInputStream

/**
 * The engines behind 中文 and 日本語, in core/ ([NativeCore]): their files, sebtype.conf (the settings the
 * phone shares with the PCs), Chinese's first-run setup, and stopping an engine nobody has used for a while.
 * Setup and engine starts run on background threads, one per engine, so 日本語 never waits behind 中文's
 * setup; typing calls [NativeCore] on the main thread.
 */
object Engines {
    const val TAG = "SebType"

    /** An engine stops this long after its language was last in use (#56), and starts again when needed. */
    private const val IDLE_MS = 3 * 60_000L

    enum class Chinese { PREPARING, READY, FAILED }

    @Volatile var chinese = Chinese.PREPARING
        private set

    /** Called on the main thread when [chinese] changes */
    var onChange: (() -> Unit)? = null

    private val worker = Executors.newSingleThreadExecutor { Thread(it, "SebType 中文") }
    private val japanese = Executors.newSingleThreadExecutor { Thread(it, "SebType 日本語") }
    private val main = Handler(Looper.getMainLooper())
    private var configured = false
    private var japaneseStopped = false

    fun sharedDir(context: Context) = File(context.noBackupFilesDir, "rime/shared")
    fun userDir(context: Context) = File(context.filesDir, "rime/user")
    private fun mozcProfile(context: Context) = File(context.applicationInfo.dataDir, ".mozc")
    private fun confFile(context: Context) = File(context.filesDir, "sebtype.conf")

    /** Sets up [NativeCore] once per process with sebtype.conf, which it writes the first time. */
    @Synchronized
    fun configure(context: Context) {
        if (configured) return
        val app = context.applicationContext
        val file = confFile(app)
        val conf = if (file.isFile) file.readText() else ""
        NativeCore.configure(
            sharedDir(app).apply { mkdirs() }.path,
            userDir(app).apply { mkdirs() }.path,
            "", // Rime logs to the system log only
            mozcProfile(app).apply { mkdirs() }.path,
            conf,
        )
        if (!file.isFile) write(file, NativeCore.settings())
        // Mozc maps its dictionary straight out of the APK, where it is stored uncompressed. The resource
        // has a real file only for Japanese, so it is opened as Japanese.
        val ja = app.createConfigurationContext(Configuration(app.resources.configuration).apply { setLocale(Locale.JAPANESE) })
        ja.resources.openRawResourceFd(R.raw.builtin_mozc_data).use {
            NativeCore.setMozcData(mozcProfile(app).path, app.applicationInfo.sourceDir, it.startOffset, it.length)
        }
        configured = true
    }

    /** sebtype.conf's options, as core/ normalised them */
    fun setting(section: String, key: String): Boolean? {
        var current = ""
        var found: Boolean? = null
        NativeCore.settings().lineSequence().forEach { line ->
            if (line.startsWith("[") && line.endsWith("]")) current = line.substring(1, line.length - 1)
            else if (current == section && line.startsWith("$key=")) found = line.substringAfter('=') == "true"
        }
        return found
    }

    fun setSetting(context: Context, section: String, key: String, on: Boolean) {
        NativeCore.setSettings("${NativeCore.settings()}[$section]\n$key=$on\n")
        write(confFile(context.applicationContext), NativeCore.settings())
    }

    /** The languages 🌐 goes through, in order (sebtype.conf's [Languages] Order). */
    fun languages(): List<Int> =
        NativeCore.settings().lineSequence().firstOrNull { it.startsWith("Order=") }?.substringAfter('=')
            ?.split(',')?.mapNotNull { mapOf("en" to NativeCore.ENGLISH, "zh" to CHINESE, "ja" to JAPANESE)[it] }
            ?.ifEmpty { null } ?: listOf(NativeCore.ENGLISH, CHINESE, JAPANESE)

    private fun write(file: File, text: String) {
        val written = File(file.path + ".new")
        written.writeText(text)
        if (!written.renameTo(file)) throw IOException("Can't write ${file.path}")
    }

    /** Gets 中文 ready in the background, unless it is or is being made ready. */
    fun prepareChinese(context: Context) {
        val app = context.applicationContext
        if (chinese == Chinese.READY) return
        worker.execute { if (chinese != Chinese.READY) setUpChinese(app) }
    }

    /** Tries again after a failure: installs the bundled data from scratch. */
    fun retryChinese(context: Context) {
        val app = context.applicationContext
        setChinese(Chinese.PREPARING)
        worker.execute {
            File(sharedDir(app), INSTALLED).delete()
            setUpChinese(app)
        }
    }

    private const val SCHEMA = "rime_ice"
    private const val ZIP = "rime/rime-data.zip"
    private const val INSTALLED = ".sebtype-bundle-version"
    private const val DEPLOYED = "build/.sebtype-deployed"

    /**
     * Installs the bundled Chinese data when it isn't installed in this version, starts Rime on it (a deploy
     * only finds it compiled already, and runs only when the data changed) and self-tests it: ranh → 然后.
     */
    private fun setUpChinese(context: Context) {
        val t0 = SystemClock.elapsedRealtime()
        setChinese(Chinese.PREPARING)
        configure(context)
        val version = context.assets.open("rime/bundle-version").bufferedReader().use { it.readText().trim() }
        val marker = File(sharedDir(context), INSTALLED)
        if (!(marker.isFile && marker.readText() == version)) {
            NativeCore.stop(CHINESE) // the install replaces the files a running Rime has open
            installChinese(context)
            marker.writeText(version) // last, so an interrupted install is redone
            Log.w(TAG, "Installed the bundled Chinese data in ${SystemClock.elapsedRealtime() - t0} ms")
        }
        NativeCore.setRimeSchema(SCHEMA)
        val deployed = File(userDir(context), DEPLOYED)
        var deploy = !(deployed.isFile && deployed.readText() == version)
        var ok: Boolean
        while (true) {
            if (deploy) {
                deployed.delete()
                NativeCore.deploy(CHINESE)
            } else {
                NativeCore.start(CHINESE)
            }
            // Rime deploys in its own thread, and takes keys once it is done.
            while (NativeCore.busy(CHINESE) && SystemClock.elapsedRealtime() - t0 < 5 * 60_000L) Thread.sleep(300)
            ok = NativeCore.running(CHINESE) && !NativeCore.busy(CHINESE) &&
                NativeCore.tryTyping(CHINESE, "ranh").any { it == "然后" || it == "然後" }
            // A record of a deploy that no longer holds: deploy once more.
            if (ok || deploy) break
            deploy = true
        }
        if (ok && deploy) deployed.writeText(version)
        // Timings only, never typed text. Log.w: release builds keep it.
        Log.w(TAG, "Set up $SCHEMA in ${SystemClock.elapsedRealtime() - t0} ms " +
            "(deployed: ${if (deploy) "yes" else "no"}), self-test ${if (ok) "passed" else "failed"}")
        setChinese(if (ok) Chinese.READY else Chinese.FAILED)
    }

    /** The bundled zip into Rime's shared dir, with the sources' times put back as the compiled files expect. */
    private fun installChinese(context: Context) {
        val shared = sharedDir(context)
        shared.deleteRecursively()
        shared.mkdirs()
        val root = shared.canonicalPath + File.separator
        ZipInputStream(context.assets.open(ZIP).buffered()).use { zip ->
            generateSequence { zip.nextEntry }.forEach { entry ->
                val out = File(shared, entry.name)
                if (!out.canonicalPath.startsWith(root)) throw IOException("Bad entry ${entry.name}")
                if (entry.isDirectory) out.mkdirs()
                else {
                    out.parentFile!!.mkdirs()
                    out.outputStream().use { zip.copyTo(it) }
                }
            }
        }
        restoreSourceTimes(shared)
        // Rime's own compiled copies from an earlier version would win over the bundled ones.
        File(userDir(context), "build").deleteRecursively()
    }

    /**
     * Rime keeps a compiled file only while its sources have the modification times recorded in it
     * (`timestamps:` in build/<schema>.yaml); extracting set them to now. Mid-second, as Rime can round an
     * exact second down.
     */
    private fun restoreSourceTimes(shared: File) {
        val entry = Regex("""^    ([\w.]+): (\d+)$""")
        File(shared, "build").listFiles { f -> f.name.endsWith(".yaml") }?.forEach { compiled ->
            var inTimes = false
            compiled.forEachLine { line ->
                if (line == "  timestamps:") inTimes = true
                else if (inTimes) {
                    val m = entry.find(line)
                    if (m == null) inTimes = false
                    else if (m.groupValues[2] != "0")
                        File(shared, "${m.groupValues[1]}.yaml").setLastModified(m.groupValues[2].toLong() * 1000 + 500)
                }
            }
        }
    }

    private fun setChinese(state: Chinese) {
        chinese = state
        main.post { onChange?.invoke() }
    }

    /** Starts 日本語 in the background, so its first key doesn't wait for Mozc to load. */
    fun prepareJapanese(context: Context) {
        val app = context.applicationContext
        japanese.execute {
            configure(app)
            if (NativeCore.running(JAPANESE)) return@execute
            val t0 = SystemClock.elapsedRealtime()
            NativeCore.start(JAPANESE)
            if (japaneseStopped) Log.w(TAG, "Mozc loaded again in ${SystemClock.elapsedRealtime() - t0} ms")
        }
    }

    private val idleStops = HashMap<Int, Runnable>()

    /** [lang] is in use (true), or was left (false): an engine left alone for [IDLE_MS] stops. */
    fun inUse(lang: Int, used: Boolean) {
        if (lang == NativeCore.ENGLISH) return
        idleStops.remove(lang)?.let { main.removeCallbacks(it) }
        if (used) return
        val stop = Runnable {
            idleStops.remove(lang)
            (if (lang == CHINESE) worker else japanese).execute {
                if (!NativeCore.running(lang)) return@execute
                if (lang == CHINESE) {
                    // Not ready first, so no key starts Rime again before the next setup.
                    setChinese(Chinese.PREPARING)
                    NativeCore.stop(CHINESE)
                    Log.w(TAG, "Rime unloaded")
                } else {
                    NativeCore.save(JAPANESE)
                    NativeCore.stop(JAPANESE)
                    japaneseStopped = true
                    Log.w(TAG, "Mozc unloaded")
                }
            }
        }
        idleStops[lang] = stop
        main.postDelayed(stop, IDLE_MS)
    }

    /** Saves what 日本語 learned (Mozc in this process saves only when asked). */
    fun saveJapanese() = japanese.execute { if (NativeCore.running(JAPANESE)) NativeCore.save(JAPANESE) }
}
