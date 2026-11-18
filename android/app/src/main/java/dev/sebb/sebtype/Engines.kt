package dev.sebb.sebtype

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
 * The engines behind English, 中文 and 日本語, in core/ ([NativeCore]): their files, sebtype.conf (the
 * settings the phone shares with the PCs), Chinese's first-run setup, English's and 中文's models copied out of the APK,
 * and stopping an engine nobody has used for a while. Setup and engine starts run on background threads, one
 * per engine, so 日本語 never waits behind 中文's setup; typing calls [NativeCore] on its engine thread
 * ([NativeCore.post]).
 */
object Engines {
    const val TAG = "SebType"

    /** An engine stops this long after its language was last in use (#56), and starts again when needed. */
    private const val IDLE_MS = 3 * 60_000L

    private const val ENGLISH_MODEL = "english/english.gguf"
    private const val CHINESE_MODEL = "chinese/chinese.gguf"

    enum class Chinese { PREPARING, READY, FAILED }

    @Volatile var chinese = Chinese.PREPARING
        private set

    /** Called on the main thread when [chinese] changes */
    var onChange: (() -> Unit)? = null

    private val worker = Executors.newSingleThreadExecutor { Thread(it, "SebType 中文") }
    private val japanese = Executors.newSingleThreadExecutor { Thread(it, "SebType 日本語") }
    private val english = Executors.newSingleThreadExecutor { Thread(it, "SebType English") }
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
        prepareEnglish(app)
        prepareChineseModel(app)
    }

    /**
     * A model in the APK's assets ([asset]) copied out once per install or update (llama.cpp maps a file of
     * its own) to the same path under noBackupFilesDir, on [on]: whether it is there already, and [copied]
     * on [on] once it is.
     */
    private fun copyModel(app: Context, asset: String, on: java.util.concurrent.Executor, copied: () -> Unit): Boolean {
        val installed = app.packageManager.getPackageInfo(app.packageName, 0).lastUpdateTime.toString()
        val model = File(app.noBackupFilesDir, asset)
        val marker = File(model.path + ".installed")
        if (marker.isFile && marker.readText() == installed && model.isFile) return true
        on.execute {
            val t0 = SystemClock.elapsedRealtime()
            model.parentFile!!.mkdirs()
            marker.delete()
            val part = File(model.path + ".part")
            app.assets.open(asset).use { input -> part.outputStream().use { input.copyTo(it, 1 shl 16) } }
            if (!part.renameTo(model)) throw IOException("Can't write ${model.path}")
            marker.writeText(installed)
            Log.w(TAG, "Copied $asset in ${SystemClock.elapsedRealtime() - t0} ms")
            copied()
        }
        return false
    }

    /**
     * English reads its dictionary straight out of the APK. Until its model is copied out English runs without
     * it, as before its first letter (it loads only once a letter is typed, Decisions #2).
     */
    private fun prepareEnglish(app: Context) {
        val model = File(app.noBackupFilesDir, ENGLISH_MODEL)
        fun setPaths(withModel: Boolean) = app.assets.openFd("english/en_US.dict").use {
            NativeCore.setEnglishPaths(app.applicationInfo.sourceDir, it.startOffset, it.length,
                if (withModel) model.path else "", File(app.filesDir, "english").apply { mkdirs() }.path)
        }
        setPaths(copyModel(app, ENGLISH_MODEL, english) { main.post { setPaths(true) } })
    }

    /**
     * 中文's model (#264) loads with Rime and stops with it. It is copied on 中文's own thread, ahead of the
     * setup's start of Rime, so a first start doesn't restart Rime; until it is there Rime runs alone. 繁 reads
     * OpenCC's tables in the installed Chinese data.
     */
    private fun prepareChineseModel(app: Context) {
        val model = File(app.noBackupFilesDir, CHINESE_MODEL).path
        val opencc = File(sharedDir(app), "opencc").path
        if (copyModel(app, CHINESE_MODEL, worker) { NativeCore.setChineseModel(model, opencc) })
            NativeCore.setChineseModel(model, opencc)
    }

    /** Saves the words English learned (AOSP's user history, in its files) */
    fun saveEnglish() = english.execute { if (NativeCore.running(NativeCore.ENGLISH)) NativeCore.save(NativeCore.ENGLISH) }

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

    /**
     * Sets 中文 up ahead of its first use when this install or update hasn't yet, so the install and the
     * deploy don't wait for its first key. Rime itself starts only for 中文: it holds about 40 MB (#351), and
     * stops again [IDLE_MS] after this setup unless 中文 is in use by then.
     */
    fun setUpChineseAhead(context: Context) {
        val app = context.applicationContext
        worker.execute {
            val version = app.assets.open("rime/bundle-version").bufferedReader().use { it.readText().trim() }
            val done = listOf(File(sharedDir(app), INSTALLED), File(userDir(app), DEPLOYED)).all { it.isFile && it.readText() == version }
            if (chinese == Chinese.READY || done) return@execute
            setUpChinese(app)
            main.post { if (CHINESE !in using) inUse(CHINESE, false) }
        }
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
    private val using = HashSet<Int>()

    /** [lang] is in use (true), or was left (false): an engine left alone for [IDLE_MS] stops. */
    fun inUse(lang: Int, used: Boolean) {
        if (lang == NativeCore.ENGLISH) return
        idleStops.remove(lang)?.let { main.removeCallbacks(it) }
        if (used) using += lang else using -= lang
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

    // --- For the settings and the sync (#254) ---

    /** Runs [block] on [lang]'s engine thread (English: 中文's), after what is queued there. */
    fun onThread(lang: Int, block: () -> Unit) = (if (lang == JAPANESE) japanese else worker).execute(block)

    /**
     * Changes Rime's files with Rime stopped (its own words, forgetting, an import), then sets 中文 up again; a
     * changed word list ([redeploy]) is compiled. [done] gets on the main thread whether 中文 is ready, false too when [block] or the setup threw.
     */
    fun whileChineseStopped(context: Context, redeploy: Boolean = false, block: () -> Unit, done: (Boolean) -> Unit = {}) {
        val app = context.applicationContext
        worker.execute {
            // done always runs: a caller may be waiting for it (Backup's restore).
            var ready = false
            try {
                setChinese(Chinese.PREPARING)
                configure(app)
                NativeCore.stop(CHINESE)
                try {
                    block()
                    if (redeploy) File(userDir(app), DEPLOYED).delete()
                } finally {
                    setUpChinese(app)
                }
                ready = chinese == Chinese.READY
            } catch (e: Exception) {
                Log.w(TAG, "Changing 中文's files failed", e)
                if (chinese != Chinese.READY) setChinese(Chinese.FAILED) // the setup itself didn't finish

            } finally {
                main.post { done(ready) }
            }
        }
    }

    /**
     * Rime's sync: merges the snapshots in its sync folder (other devices', an import) into the learned words
     * and writes this phone's own. Blocks until done; false when 中文 was never set up or Rime failed.
     */
    fun syncChinese(context: Context): Boolean = worker.submit<Boolean> {
        val app = context.applicationContext
        if (!File(sharedDir(app), INSTALLED).isFile) return@submit false
        configure(app)
        val wasRunning = NativeCore.running(CHINESE)
        var ok = NativeCore.start(CHINESE)
        if (ok) NativeCore.save(CHINESE)
        val t0 = SystemClock.elapsedRealtime()
        // The merge runs in Rime's own thread.
        while (ok && NativeCore.busy(CHINESE)) {
            if (SystemClock.elapsedRealtime() - t0 > 60_000L) ok = false else Thread.sleep(200)
        }
        Log.w(TAG, "Synced 中文's learned words in ${SystemClock.elapsedRealtime() - t0} ms, ${if (ok) "done" else "failed"}")
        if (!wasRunning) NativeCore.stop(CHINESE)
        ok
    }.get()

    fun mozcDir(context: Context) = mozcProfile(context.applicationContext)

    /**
     * Adds [ini] (sebtype.conf lines, the last of a key winning) to the settings and saves them, on the engine
     * thread after the keys typed before (#241); [done] runs on the main thread after.
     */
    fun changeSettings(context: Context, ini: String, done: () -> Unit = {}) {
        val app = context.applicationContext
        NativeCore.post {
            configure(app)
            setSettings(settings() + ini)
            write(confFile(app), settings())
            main.post(done)
        }
    }

    /** sebtype.conf as a whole, for a backup; [replaceSettings] takes one back. */
    fun settingsFile(context: Context) = confFile(context.applicationContext)

    /** As [changeSettings], with [ini] as the whole of them; blocks until they are written, and throws if they can't be. Not from the main thread, which NativeCore's waits for. */
    fun replaceSettings(context: Context, ini: String) {
        val app = context.applicationContext
        val task = java.util.concurrent.FutureTask<Unit> {
            configure(app)
            NativeCore.setSettings(ini)
            write(confFile(app), NativeCore.settings())
        }
        // On NativeCore's thread itself a post would wait for this call to end.
        if (NativeCore.onEngineThread()) task.run() else NativeCore.post { task.run() }
        try {
            task.get()
        } catch (e: java.util.concurrent.ExecutionException) {
            throw e.cause ?: e
        }
    }
}
