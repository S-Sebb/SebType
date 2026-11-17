package dev.sebb.sebtype.next.data

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.PreferencesSerializer
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.core.stringSetPreferencesKey
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
     * Setup's record (#285): none until the settings first open, [SETUP_TIPS_DUE] while setup runs, [SETUP_DONE]
     * after its last step's Done, or at once after an update over today's app ([setup]). [SETUP_UNSEEN] is a
     * backup imported before it had one ([imported]). It belongs to this install: no backup has it.
     */
    val SETUP = Option(intPreferencesKey("sebtype_setup"), 0)
    const val SETUP_UNSEEN = 0
    const val SETUP_TIPS_DUE = 1
    const val SETUP_DONE = 2
    /**
     * Today's app's languages, globe order and layouts, which it saves as it first starts; the new app never
     * writes them, but keeps them for a backup that goes back to today's app.
     */
    private val TODAYS_SUBTYPES = stringSetPreferencesKey("subtypes")
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

    /** Setup's record, if any, and whether today's app was here before (an update over it, #285) */
    fun setup(context: Context): Flow<Pair<Int?, Boolean>> =
        context.applicationContext.store.data.map { it[SETUP.key] to (TODAYS_SUBTYPES in it) }

    fun <T> set(context: Context, option: Option<T>, value: T) {
        val app = context.applicationContext
        scope.launch { app.store.edit { it[option.key] = value } }
    }

    /** Drops options the app no longer keeps there ([Migration]) */
    suspend fun remove(context: Context, keys: List<Preferences.Key<*>>) {
        context.applicationContext.store.edit { prefs -> keys.forEach { prefs.remove(it) } }
    }

    /** What an import changed: the file before it and after ([undo]) */
    class Imported(val before: Preferences, val after: Preferences)

    /** Takes a backup's options, in one edit with what this phone had ([imported]). */
    suspend fun import(context: Context, backup: Preferences) = import(context.applicationContext.store, backup)

    suspend fun import(store: DataStore<Preferences>, backup: Preferences): Imported {
        lateinit var before: Preferences
        val after = store.edit {
            before = it.toPreferences()
            val next = imported(backup, before)
            it.clear()
            it += next
        }
        return Imported(before, after)
    }

    /**
     * Takes back what [import] changed, for an import that failed: each option still as the import left it
     * goes back, and what was written since (setup's Done while the engines restarted, an option) stays.
     */
    suspend fun undo(context: Context, import: Imported) = undo(context.applicationContext.store, import)

    suspend fun undo(store: DataStore<Preferences>, import: Imported) {
        store.edit { now ->
            @Suppress("UNCHECKED_CAST")
            for (key in (import.before.asMap().keys + import.after.asMap().keys) as Set<Preferences.Key<Any>>) {
                if (now[key] != import.after[key]) continue
                val old = import.before[key]
                if (old == null) now.remove(key) else now[key] = old
            }
        }
    }

    /**
     * [backup] as an import leaves it on [phone], with [phone]'s setup record (#285): a backup from a set-up
     * phone mustn't skip setup on a new one, nor an older backup bring it back. A phone without one gets one
     * from what it had, so the backup's languages ([TODAYS_SUBTYPES]) never pass for an update over today's app.
     */
    fun imported(backup: Preferences, phone: Preferences): Preferences = backup.toMutablePreferences().apply {
        this[SETUP.key] = phone[SETUP.key] ?: if (TODAYS_SUBTYPES in phone) SETUP_DONE else SETUP_UNSEEN
    }

    /** The options as a backup has them: all but setup's record */
    suspend fun exported(context: Context): ByteArray = exported(context.applicationContext.store)

    suspend fun exported(store: DataStore<Preferences>): ByteArray {
        val prefs = store.data.first().toMutablePreferences().apply { remove(SETUP.key) }
        return okio.Buffer().also { PreferencesSerializer.writeTo(prefs, it) }.readByteArray()
    }

    /** The file, whether there are options to back up */
    fun file(context: Context) = java.io.File(context.filesDir, "datastore/settings.preferences_pb")
}
