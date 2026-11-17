package dev.sebb.sebtype.next.data

import android.content.Context
import android.util.Log
import androidx.datastore.preferences.core.stringPreferencesKey
import dev.sebb.sebtype.next.Action
import dev.sebb.sebtype.next.Engines
import dev.sebb.sebtype.next.Mode
import java.io.File
import kotlin.math.roundToInt

/** Where the new app keeps its data besides Rime's and Mozc's folders ([Engines]). */
object Data {
    /** English's learned words (core/'s English engine, `en_history`) */
    fun englishDir(context: Context) = File(context.filesDir, "english")
}

/**
 * An update over today's app (FUTO Keyboard's, before #191 stage 6) keeps the user's data (#254). Most of it is
 * already where the new app reads it: DataStore's `settings`, sebtype.conf, Rime's user folder (learned words,
 * My words, the word list, the sync folders) and Mozc's profile (learned words, its user dictionary). The rest
 * moves here once (the options in SharedPreferences: [Prefs]), the first time the app starts after the update; each step finds nothing to do afterwards.
 */
object Migration {
    private const val TAG = "SebType"

    // Today's app's own places, as it keeps them on the phone
    private const val ENGLISH_HISTORY = "UserHistoryDictionary.en_US.dict"
    private const val OLD_PREFS = "_preferences"
    private const val OLD_INCOGNITO = "pref_sebtype_incognito"
    private const val OLD_LEARNING = "pref_key_use_personalized_dicts"

    fun run(context: Context) {
        // English's learned words: the same AOSP format; core/'s engine learns them anew on its first start.
        val english = File(context.filesDir, ENGLISH_HISTORY)
        if (english.isDirectory) {
            val to = File(Data.englishDir(context).apply { mkdirs() }, ENGLISH_HISTORY)
            to.deleteRecursively()
            if (english.renameTo(to)) Log.w(TAG, "Moved English's learned words") else Log.w(TAG, "Can't move English's learned words")
        }
        val old = context.getSharedPreferences(context.packageName + OLD_PREFS, Context.MODE_PRIVATE)
        // Learning off (#31) is sebtype.conf's now, which the PCs share.
        if (old.contains(OLD_LEARNING)) {
            if (!old.getBoolean(OLD_LEARNING, true)) Engines.changeSettings(context, "[Learning]\nOn=false\n")
            old.edit().remove(OLD_LEARNING).apply()
        }
        // Incognito (#31) stays on through the update.
        if (old.contains(OLD_INCOGNITO)) {
            context.getSharedPreferences("keyboard", Context.MODE_PRIVATE).edit()
                .putBoolean("incognito", old.getBoolean(OLD_INCOGNITO, false)).apply()
            old.edit().remove(OLD_INCOGNITO).apply()
        }
    }

    // Today's keyboard's own options in DataStore's file, which the new app keeps in "keyboard"'s SharedPreferences
    private val OLD_ACTIONS = stringPreferencesKey("favorite_actions_s")
    private val OLD_EMOJI = stringPreferencesKey("last_used_emoji")
    private val OLD_SIZES = mapOf("port" to stringPreferencesKey("keyboard_settings_portrait"), "land" to stringPreferencesKey("keyboard_settings_landscape"))
    private val OLD_ACTION_IDS = mapOf(
        "emoji" to Action.EMOJI, "settings" to Action.SETTINGS, "paste" to Action.PASTE, "undo" to Action.UNDO,
        "redo" to Action.REDO, "switch_language" to Action.LANGUAGE, "clipboard_history" to Action.CLIPBOARD,
        "cut" to Action.CUT, "copy" to Action.COPY, "select_all" to Action.SELECT_ALL, "keyboard_modes" to Action.MODES,
        "incognito" to Action.INCOGNITO,
    )

    /**
     * Once the options are read: today's fuzzy pinyin was its own, Rime gets it as SebType's schema patch;
     * the action bar's buttons, the keyboard's mode and height and the recent emoji move to the keyboard's.
     */
    suspend fun afterOptions(context: Context) {
        val fuzzy = ChineseData.Fuzzy.of(Prefs[Prefs.FUZZY])
        if (fuzzy.isNotEmpty() && !ChineseData.patchFile(context).exists()) ChineseData.setFuzzy(context, fuzzy)

        val old = Prefs.current
        val legacy = listOf(OLD_ACTIONS, OLD_EMOJI, *OLD_SIZES.values.toTypedArray()).filter { it in old }
        if (legacy.isEmpty()) return
        val prefs = context.getSharedPreferences("keyboard", Context.MODE_PRIVATE)
        val m = context.resources.displayMetrics
        val values = keyboardPrefs(old, prefs.all.keys, todayHeights(minOf(m.widthPixels, m.heightPixels) / m.density, maxOf(m.widthPixels, m.heightPixels) / m.density))
        val written = prefs.edit().apply {
            values.forEach { (key, value) ->
                when (value) {
                    is String -> putString(key, value)
                    is Float -> putFloat(key, value)
                    is Boolean -> putBoolean(key, value)
                }
            }
        }.commit()
        // Kept until they are written: the next start tries again.
        if (!written) {
            Log.w(TAG, "Can't write today's keyboard options")
            return
        }
        Prefs.remove(context, legacy)
        Log.w(TAG, "Moved today's keyboard options")
    }

    /**
     * What today's options in [old] become in the keyboard's SharedPreferences, but for the keys it already
     * has ([have]): set in the new app, or by an earlier run, they win. [heights]: [todayHeights].
     */
    fun keyboardPrefs(old: androidx.datastore.preferences.core.Preferences, have: Set<String>, heights: Map<String, Today>): Map<String, Any> {
        val out = LinkedHashMap<String, Any>()
        old[OLD_ACTIONS]?.let { ids -> out["actions"] = actions(ids).joinToString(",") { it.name } }
        old[OLD_EMOJI]?.let { out["emoji_recent"] = emoji(it).joinToString("\n") }
        OLD_SIZES.forEach { (orientation, key) ->
            val size = old[key]?.let { size(it, orientation == "land", heights.getValue(orientation)) } ?: return@forEach
            out["mode_$orientation"] = size.mode.name
            out["height_$orientation"] = size.height
            out["one_handed_left_$orientation"] = size.left
            size.floatingWidth?.let { out["floating_width_$orientation"] = it }
            size.floatingHeight?.let { out["floating_height_$orientation"] = it }
        }
        return out.filterKeys { it !in have }
    }

    /** Today's keyboard before any change in an orientation: its height in dp, and its heightMultiplier */
    class Today(val height: Float, val multiplier: Float)

    // app/'s res values: config_default_keyboard_height and config_min/max_keyboard_height (a min below 0: of
    // the screen's width), by the qualifiers of their folder: smallest width, long, land
    private class Res(val sw: Int, val long: Boolean, val land: Boolean, val height: Float?, val min: Float?, val max: Float?)
    private val RES = listOf(
        Res(0, false, false, 205.6f, -0.6105f, 0.46f),
        Res(0, false, true, 176f, 0.45f, null),
        Res(600, false, false, 302.4f, -0.35f, 0.46f),
        Res(600, true, true, 283.5f, 0.40f, null),
        Res(768, false, false, 365.4f, -0.35f, 0.46f),
        Res(768, true, true, 302.4f, 0.35f, null),
    )

    /**
     * Today's keyboard before any change, per orientation, on a screen [shortDp] by [longDp]: its default
     * height within its min and max (ResourceUtils.getDefaultKeyboardHeight), each value from the folder
     * Android picks (the largest smallest width that fits, then long, then land), and getDefaultSettingForKind's
     * multiplier (0.8 in portrait above 600 dp, 0.9 in landscape).
     */
    fun todayHeights(shortDp: Float, longDp: Float): Map<String, Today> {
        val long = longDp * 3 / 5 >= shortDp - 1 // Configuration's SCREENLAYOUT_LONG_YES
        fun today(land: Boolean): Today {
            val width = if (land) longDp else shortDp
            val height = if (land) shortDp else longDp
            fun value(of: (Res) -> Float?) = RES.filter { of(it) != null && it.sw <= shortDp && (long || !it.long) && (land || !it.land) }
                .maxWith(compareBy<Res>({ it.sw }, { it.long }, { it.land })).let(of)!!
            val min = value { it.min }.let { if (it < 0) -it * width else it * height }
            val multiplier = if (land) 0.9f else if (shortDp > 600) 0.8f else 1f
            return Today(maxOf(minOf(value { it.height }, value { it.max } * height), min), multiplier)
        }
        return mapOf("port" to today(false), "land" to today(true))
    }

    /** Today's action bar buttons, as its ids ("emoji,undo,…"); those the new bar hasn't go. */
    fun actions(ids: String) = ids.split(',').mapNotNull { OLD_ACTION_IDS[it.trim()] }.distinct().take(Action.MAX_PINNED)

    /** Today's recent emoji, most recent first */
    fun emoji(recent: String) = recent.split("<|>").filter { it.isNotBlank() }.distinct()

    /** [floatingWidth] (dp) and [floatingHeight]: the floating keyboard's, kept apart as today's; null if unchanged */
    class Size(val mode: Mode, val height: Float, val left: Boolean, val floatingWidth: Float? = null, val floatingHeight: Float? = null)

    /**
     * Today's mode and height for an orientation, from its JSON (SavedKeyboardSizingSettings), with its keyboard
     * there before any change [today] ([todayHeights]). Today's keys take (the height + the mode's height
     * addition − its bottom padding) × heightMultiplier (KeyboardSizingCalculator.calculate); the new app's
     * height is that over what the same mode took before any change (getDefaultSettingForKind), so an unchanged
     * one is 1. Floating keeps its own: floatingHeightDp over its 240 dp before any change, the docked height
     * then being Regular's.
     */
    fun size(json: String, landscape: Boolean, today: Today): Size? {
        fun field(name: String, of: String = json) = Regex(""""$name"\s*:\s*"?([\w.+-]+)""").find(of)?.groupValues?.get(1)
        fun number(name: String) = field(name)?.toFloatOrNull()
        fun bottom(rect: String) = Regex(""""$rect"\s*:\s*\{([^}]*)\}""").find(json)?.groupValues?.get(1)?.let { field("bottom", it)?.toFloatOrNull() }
        val mode = when (field("currentMode")) {
            "Regular" -> Mode.STANDARD
            "Split" -> Mode.SPLIT
            "OneHanded" -> Mode.ONE_HANDED
            "Floating" -> Mode.FLOATING
            else -> return null
        }
        val floating = (number("floatingHeightDp") ?: FLOATING_HEIGHT) / FLOATING_HEIGHT
        val ratio = run {
            val standardBottom = if (landscape) 2f else 10f
            // The mode's height addition, its bottom padding, and that padding before any change
            val (addition, padding, standardPadding) = when (mode) {
                Mode.SPLIT -> Triple(number("splitHeightAdditionDp"), bottom("splitPaddingDp"), standardBottom)
                Mode.ONE_HANDED -> Triple(number("oneHandedHeightAdditionDp"), bottom("oneHandedRectDp"), 30f)
                else -> Triple(number("heightAdditionDp"), bottom("paddingDp"), standardBottom)
            }
            val keys = (today.height + (addition ?: 0f) - (padding ?: standardPadding)) * (number("heightMultiplier") ?: today.multiplier)
            keys / ((today.height - standardPadding) * today.multiplier)
        }
        fun step(ratio: Float) = ((ratio / Mode.HEIGHT_STEP).roundToInt() * Mode.HEIGHT_STEP).coerceIn(Mode.MIN_HEIGHT, Mode.MAX_HEIGHT)
        // Floating's own height in today's limits, the window's left to the keyboard (it can't know it here)
        return Size(mode, step(ratio), field("oneHandedDirection") == "Left",
            number("floatingWidthDp")?.takeIf { it != FLOATING_WIDTH }?.coerceAtLeast(Mode.FLOATING_MIN_WIDTH_DP),
            floating.takeIf { it != 1f }?.coerceAtLeast(Mode.FLOATING_MIN_HEIGHT_DP / FLOATING_HEIGHT))
    }

    // Today's floating keyboard's height and width before any change
    private const val FLOATING_HEIGHT = 240f
    private const val FLOATING_WIDTH = 360f
}
