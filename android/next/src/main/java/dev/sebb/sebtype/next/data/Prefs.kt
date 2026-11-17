package dev.sebb.sebtype.next.data

import android.content.Context
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.SharedPreferencesMigration
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * The phone-only options (§3 of docs/plans/android-own-keyboard.md): DataStore's `settings` file, the one
 * today's app keeps, so an update over it keeps them. The options the phone shares with the PCs are in
 * sebtype.conf instead ([dev.sebb.sebtype.next.Engines]).
 */
object Prefs {
    class Option<T>(val key: Preferences.Key<T>, val default: T)

    // Today's app's own names (#254), so its values carry over as they are ([OLD_SHARED]).
    val NUMBER_ROW = Option(booleanPreferencesKey("pref_number_row"), false) // hidden by default (#161)
    val KEY_POPUP = Option(booleanPreferencesKey("popup_on"), true)
    val VIBRATE = Option(booleanPreferencesKey("vibrate_on"), true)
    val SOUND = Option(booleanPreferencesKey("sound_on"), false)
    /** The keys' vibration, in percent of the motor's strength (#257) */
    val VIBRATE_STRENGTH = Option(intPreferencesKey("sebtype_vibrate_strength"), 50)
    /** The small digits and symbols in the keys' corners, a long press's first choice (#257) */
    val SHOW_HINTS = Option(booleanPreferencesKey("sebtype_show_hints"), true)
    val LONG_PRESS_MS = Option(intPreferencesKey("pref_key_longpress_timeout"), 300)
    val AUTOCORRECT = Option(booleanPreferencesKey("pref_key_auto_correction"), true)
    val CAPITALISE = Option(booleanPreferencesKey("auto_cap"), true)
    val DOUBLE_SPACE_PERIOD = Option(booleanPreferencesKey("pref_key_use_double_space_period"), true)
    val EMOJI_SUGGESTIONS = Option(booleanPreferencesKey("suggestEmojis"), true)
    val CLIPBOARD_HISTORY = Option(booleanPreferencesKey("enableClipboardHistory"), false)
    /**
     * Setup's last step, the tips (#285): [SETUP_UNSEEN] until the settings first open, then [SETUP_TIPS_DUE]
     * for a new user (setup shown) or [SETUP_DONE] for one whose SebType was already on, and [SETUP_DONE]
     * after the tips' Done.
     */
    val SETUP = Option(intPreferencesKey("sebtype_setup"), 0)
    const val SETUP_UNSEEN = 0
    const val SETUP_TIPS_DUE = 1
    const val SETUP_DONE = 2
    /** [ChineseData.Fuzzy.of] */
    val FUZZY = Option(stringPreferencesKey("ChineseIME_fuzzy_pinyin"), "")

    /** The options today's app keeps in Android's SharedPreferences, not DataStore; the first read takes them over. */
    private val OLD_SHARED = listOf(KEY_POPUP, VIBRATE, SOUND, LONG_PRESS_MS, AUTOCORRECT, CAPITALISE, DOUBLE_SPACE_PERIOD)
        .map { it.key.name }.toSet()

    private val Context.store by preferencesDataStore(
        name = "settings",
        produceMigrations = { listOf(SharedPreferencesMigration(it, it.packageName + "_preferences", OLD_SHARED)) },
    )
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** The options as last read, for the keyboard, which never waits for the file. */
    @Volatile var current: Preferences = emptyPreferences()
        private set

    /** Keeps [current] up to date for this process; the application calls it once. */
    fun watch(context: Context) {
        val app = context.applicationContext
        scope.launch {
            current = app.store.data.first()
            Migration.afterOptions(app)
            app.store.data.collect { current = it }
        }
    }

    operator fun <T> get(option: Option<T>): T = current[option.key] ?: option.default

    fun <T> flow(context: Context, option: Option<T>): Flow<T> =
        context.applicationContext.store.data.map { it[option.key] ?: option.default }

    fun <T> set(context: Context, option: Option<T>, value: T) {
        val app = context.applicationContext
        scope.launch { app.store.edit { it[option.key] = value } }
    }

    /** Drops options the app no longer keeps there ([Migration]) */
    suspend fun remove(context: Context, keys: List<Preferences.Key<*>>) {
        context.applicationContext.store.edit { prefs -> keys.forEach { prefs.remove(it) } }
    }

    /** The whole file as it is now */
    suspend fun read(context: Context): Preferences = context.applicationContext.store.data.first()

    /** Takes [prefs] as the whole file (a backup's). */
    suspend fun replace(context: Context, prefs: Preferences) {
        context.applicationContext.store.edit {
            it.clear()
            it += prefs
        }
    }

    /** The whole file, for a backup */
    fun file(context: Context) = java.io.File(context.filesDir, "datastore/settings.preferences_pb")
}
