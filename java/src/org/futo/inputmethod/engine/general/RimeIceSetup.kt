package org.futo.inputmethod.engine.general

import android.content.Context
import android.os.SystemClock
import android.util.Log
import icu.astronot233.rime.Rime
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.futo.inputmethod.latin.settings.Settings
import org.futo.inputmethod.latin.uix.PreferenceUtils
import org.futo.inputmethod.latin.uix.actions.throwIfDebug
import org.futo.inputmethod.latin.uix.getSetting
import org.futo.inputmethod.latin.utils.toEnumOrNull
import java.io.File
import java.util.Locale

/**
 * Gets Chinese ready: installs the bundled rime-ice when needed ([RimeIceBundle]), deploys it with
 * SebType's settings patch and self-tests it. One run at a time on a background thread, shared by the
 * keyboard and the background triggers (the setup screen and app updates), so Chinese is usually ready
 * before it is first typed. librime is one per process, so its [Rime] is too.
 */
object RimeIceSetup {
    private const val TAG = "ChineseIME (rime)"

    // How long a deploy may take before setup fails. The tables come prebuilt, so this is far more
    // than a deploy needs.
    private const val DEPLOY_TIMEOUT_MS = 5 * 60_000L

    sealed interface State {
        /** Installing ([percent] of rime-ice extracted) or deploying ([percent] null). */
        data class Preparing(val percent: Int?) : State
        data object Ready : State
        data object Failed : State
    }

    private val mutableState = MutableStateFlow<State>(State.Preparing(null))
    val state: StateFlow<State> = mutableState

    /** What the settings patch is made from; equal configurations need no new deploy. */
    data class Configuration(
        val schema: String,
        val learning: Boolean,
        val simplification: Boolean,
        val autocorrect: Boolean,
        val fuzzyMode: Set<ChineseIMESettings.FuzzyPinyinModes>
    ) {
        fun patch() = buildString {
            appendLine("patch:")

            appendLine("    translator/enable_correction: $autocorrect")
            appendLine("    translator/enable_user_dict: $learning")

            appendLine("    switches/+:")
            appendLine("        - name: futo_zh_simp")
            appendLine("          reset: ${if(simplification) 1 else 0}")
            appendLine("          states: [ 漢字, 汉字 ]")
            appendLine("    simplifier/option_name: futo_zh_simp")

            // Fuzzy pinyin only added to pinyin layouts. Appended (FUTO 68ead9599): a bare
            // `speller/algebra:` would replace rime-ice's own rules, which give abbreviated pinyin.
            if(schema == RimeIceBundle.SCHEMA && fuzzyMode.isNotEmpty()) {
                appendLine("    speller/algebra/+:")
                fuzzyMode.forEach { mode ->
                    mode.schemePatch.forEach { appendLine("        - $it") }
                }
            }
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutex = Mutex()
    private var rime: Rime? = null
    private var started = false
    private var readyFor: String? = null

    /** The process's Rime; creating it starts librime, so the first call is best off the main thread. */
    @Synchronized
    fun rime(context: Context): Rime = rime ?: run {
        val shared = ChineseIME.getShared(context).apply { mkdirs() }
        val user = ChineseIME.getUser(context).apply { mkdirs() }
        Rime(shared.path, user.path, context.packageName).also { rime = it }
    }

    /** Starts setting up Chinese for SebType's Chinese layout with the current settings; [onDone] runs after. */
    @JvmStatic
    @JvmOverloads
    fun prepareInBackground(context: Context, onDone: Runnable? = null) {
        val app = context.applicationContext
        scope.launch {
            try {
                ensure(app, defaultConfiguration(app))
            } catch(e: Exception) {
                Log.e(TAG, "Setting up Rime in the background failed", e)
            } finally {
                onDone?.run()
            }
        }
    }

    /** The configuration of the Chinese QWERTY layout in an ordinary text field, read from the settings. */
    private fun defaultConfiguration(context: Context): Configuration {
        val prefs = PreferenceUtils.getDefaultSharedPreferences(context)
        val pinyinScheme = context.getSetting(ChineseIMESettings.PinyinSchemeSetting)
            .toEnumOrNull<ChineseIMESettings.PinyinScheme>() ?: ChineseIMESettings.PinyinScheme.FullPinyin
        return Configuration(
            schema = schemaFor("qwerty", pinyinScheme)!!,
            learning = prefs.getBoolean(Settings.PREF_KEY_USE_PERSONALIZED_DICTS, true),
            simplification = isSimplifiedChinese(context, Locale.forLanguageTag("zh")),
            autocorrect = prefs.getBoolean(Settings.PREF_AUTO_CORRECTION, true)
                    || prefs.getBoolean(Settings.PREF_SHOW_SUGGESTIONS, true),
            fuzzyMode = ChineseIMESettings.FuzzyPinyinModes.fromCommaString(
                context.getSetting(ChineseIMESettings.FuzzyPinyinSetting)
            )
        )
    }

    fun schemaFor(layoutHint: String?, pinyinScheme: ChineseIMESettings.PinyinScheme) = when(layoutHint) {
        "qwerty" -> if(pinyinScheme == ChineseIMESettings.PinyinScheme.FullPinyin) RimeIceBundle.SCHEMA
                    else pinyinScheme.rimeId
        "stroke" -> "stroke"
        null -> null
        else -> {
            throwIfDebug(IllegalStateException("Invalid layout hint '$layoutHint'"))
            "luna_pinyin"
        }
    }

    fun isSimplifiedChinese(context: Context, locale: Locale): Boolean {
        if (locale.language != "zh") return false
        return when(context.getSetting(ChineseIMESettings.SimplificationSetting)
            .toEnumOrNull<ChineseIMESettings.ChineseSimplificationMode>()) {
            ChineseIMESettings.ChineseSimplificationMode.Simplified -> true
            ChineseIMESettings.ChineseSimplificationMode.Traditional -> false
            else -> locale.script.takeIf { it.isNotEmpty() }?.equals("Hans", ignoreCase = true)
                ?: when (locale.country.uppercase()) {
                    "TW", "HK", "MO" -> false
                    else -> true
                }
        }
    }

    /**
     * Makes Rime ready for [config] and returns whether it passed its self-test. Quick when it already
     * is; a new process skips the deploy when the last good one (recorded in user/build, which the
     * bundle's install clears) was for the same bundle and patch.
     */
    suspend fun ensure(context: Context, config: Configuration): Boolean = withContext(Dispatchers.IO) {
        mutex.withLock {
            val patch = config.patch()
            val key = "${RimeIceBundle.bundledVersion(context)}\n${config.schema}\n$patch"
            if(readyFor == key) return@withLock true
            readyFor = null

            val t0 = SystemClock.elapsedRealtime()
            val rime = rime(context)
            if(!RimeIceBundle.isInstalled(context)) {
                mutableState.value = State.Preparing(0)
                // The install replaces the files a running Rime has open.
                stop(rime)
                RimeIceBundle.install(context) { mutableState.value = State.Preparing(it) }
                // Log.w: release builds strip Log.i (#29); timings only, no typed text
                Log.w(TAG, "Installed the bundled rime-ice in ${SystemClock.elapsedRealtime() - t0} ms")
            }
            mutableState.value = State.Preparing(null)

            val deployed = File(ChineseIME.getUser(context), "build/.sebtype-deployed")
            var deploy = !(deployed.isFile && deployed.readText() == key)
            var ok = false
            while(true) {
                // Rime's deploy restarts a running Rime; it hangs on one never started.
                if(!started) {
                    rime.startup(false)
                    started = true
                }
                if(deploy) {
                    val custom = File(ChineseIME.getUser(context), "${config.schema}.custom.yaml")
                    if(!custom.isFile || custom.readText() != patch) custom.writeText(patch)
                    deployed.delete()
                    rime.deploy()
                }

                // Deploying runs in the background; the schema is selectable once it is done.
                while(SystemClock.elapsedRealtime() - t0 < DEPLOY_TIMEOUT_MS) {
                    if(rime.selectSchema(config.schema)) { ok = true; break }
                    delay(300L)
                }
                if(ok && config.schema == RimeIceBundle.SCHEMA) ok = selfTest(rime)
                // A stale record of an earlier deploy: deploy once more.
                if(ok || deploy) break
                deploy = true
            }
            if(ok && deploy) deployed.writeText(key)
            Log.w(TAG, "Set up ${config.schema} in ${SystemClock.elapsedRealtime() - t0} ms " +
                    "(deployed: ${if(deploy) "yes" else "no"}), self-test ${if(ok) "passed" else "failed"}")

            if(ok) readyFor = key
            mutableState.value = if(ok) State.Ready else State.Failed
            ok
        }
    }

    /** Runs [block] with Rime stopped (to change its files); the next [ensure] starts it again. */
    suspend fun whileStopped(context: Context, block: () -> Unit) = withContext(Dispatchers.IO) {
        mutex.withLock {
            stop(rime(context))
            readyFor = null
            mutableState.value = State.Preparing(null)
            block()
        }
    }

    private fun stop(rime: Rime) {
        if(started) rime.shutdown()
        started = false
    }

    private suspend fun selfTest(rime: Rime): Boolean {
        rime.clearComposition()
        rime.simulateKeySequence(RimeIceBundle.SELF_TEST_INPUT)
        val passed = rime.getCandidates().any { it.text == RimeIceBundle.SELF_TEST_WORD }
        rime.clearComposition()
        return passed
    }
}
