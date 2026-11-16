package dev.sebb.sebtype.next.data

import android.content.Context
import android.util.Log
import dev.sebb.sebtype.next.Engines
import java.io.File

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

    /** Once the options are read: today's fuzzy pinyin was its own; Rime gets it as SebType's schema patch. */
    fun afterOptions(context: Context) {
        val fuzzy = ChineseData.Fuzzy.of(Prefs[Prefs.FUZZY])
        if (fuzzy.isNotEmpty() && !ChineseData.patchFile(context).exists()) ChineseData.setFuzzy(context, fuzzy)
    }
}
