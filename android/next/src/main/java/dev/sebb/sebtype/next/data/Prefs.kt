package dev.sebb.sebtype.next.data

import android.content.Context
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringSetPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

/**
 * The phone-only options (§3 of docs/plans/android-own-keyboard.md): DataStore's `settings` file, the one
 * today's app keeps, so an update over it keeps them. The options the phone shares with the PCs are in
 * sebtype.conf instead ([dev.sebb.sebtype.next.Engines]).
 */
object Prefs {
    class Option<T>(val key: Preferences.Key<T>, val default: T)

    // Today's app's own names (#254), so its values carry over as they are.
    val NUMBER_ROW = Option(booleanPreferencesKey("pref_number_row"), false) // hidden by default (#161)
    val KEY_POPUP = Option(booleanPreferencesKey("popup_on"), true)
    val VIBRATE = Option(booleanPreferencesKey("vibrate_on"), true)
    val SOUND = Option(booleanPreferencesKey("sound_on"), false)
    val LONG_PRESS_MS = Option(intPreferencesKey("pref_key_longpress_timeout"), 300)
    val AUTOCORRECT = Option(booleanPreferencesKey("pref_key_auto_correction"), true)
    val CAPITALISE = Option(booleanPreferencesKey("auto_cap"), true)
    val DOUBLE_SPACE_PERIOD = Option(booleanPreferencesKey("pref_key_use_double_space_period"), true)
    val EMOJI_SUGGESTIONS = Option(booleanPreferencesKey("emoji_suggestions"), true)
    val CLIPBOARD_HISTORY = Option(booleanPreferencesKey("enableClipboardHistory"), false)
    /** [ChineseData.Fuzzy]'s names */
    val FUZZY = Option(stringSetPreferencesKey("sebtype_fuzzy_pinyin"), emptySet<String>())

    private val Context.store by preferencesDataStore(name = "settings")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    /** The options as last read, for the keyboard, which never waits for the file. */
    @Volatile var current: Preferences = emptyPreferences()
        private set

    /** Keeps [current] up to date for this process; the application calls it once. */
    fun watch(context: Context) {
        val app = context.applicationContext
        scope.launch { app.store.data.collect { current = it } }
    }

    operator fun <T> get(option: Option<T>): T = current[option.key] ?: option.default

    fun <T> flow(context: Context, option: Option<T>): Flow<T> =
        context.applicationContext.store.data.map { it[option.key] ?: option.default }

    fun <T> set(context: Context, option: Option<T>, value: T) {
        val app = context.applicationContext
        scope.launch { app.store.edit { it[option.key] = value } }
    }

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
