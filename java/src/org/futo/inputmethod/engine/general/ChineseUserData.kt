package org.futo.inputmethod.engine.general

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import icu.astronot233.rime.Rime
import org.futo.inputmethod.latin.uix.SettingsKey
import org.futo.inputmethod.latin.uix.getSetting
import java.io.File
import java.io.InputStream

/**
 * SebType's Chinese options and personal data (#41): two of rime-ice's switches, set at run time so no
 * deploy is needed; the user's own words, kept in rime-ice's custom_phrase; and forgetting what Rime
 * learned while keeping those words.
 */
object ChineseOptions {
    val EmojiInCandidates = SettingsKey(booleanPreferencesKey("sebtype_zh_emoji"), true)
    val FullWidthPunctuation = SettingsKey(booleanPreferencesKey("sebtype_zh_full_width_punctuation"), true)

    // The layout's punctuation keys type full-width marks themselves, which Rime passes through.
    private val halfWidth = mapOf('，' to ',', '。' to '.', '？' to '?', '！' to '!', '：' to ':', '；' to ';')
        .entries.associate { it.key.code to it.value.code }
    @Volatile private var fullWidth = true

    /** Selecting a schema resets rime-ice's switches, so this runs for every new text field. */
    suspend fun apply(context: Context, rime: Rime) {
        fullWidth = context.getSetting(FullWidthPunctuation)
        rime.setOption("emoji", context.getSetting(EmojiInCandidates))
        rime.setOption("ascii_punct", !fullWidth)
    }

    /** A key's code point as Chinese types it: the layout's full-width marks become ASCII ones when off. */
    fun punctuation(codePoint: Int) = if(fullWidth) codePoint else halfWidth[codePoint] ?: codePoint
}

data class ChineseWord(val word: String, val pinyin: String)

/**
 * The user's words: Rime reads `custom_phrase.txt` from the user dir before the shared one, so the
 * user's copy is rime-ice's own file (as installed when the words were last changed) with the user's
 * words after [MARKER]. rime-ice ranks these phrases first for an exactly typed code.
 */
object ChineseMyWords {
    private const val FILE = "custom_phrase.txt"
    private const val MARKER = "# SebType: My words"
    private val PINYIN = Regex("[a-z]+")

    private fun userFile(context: Context) = File(ChineseIME.getUser(context), FILE)

    /** The code Rime matches: lowercase pinyin letters only, so "Xiao Ming" and "xiao'ming" both work. */
    fun normalizePinyin(text: String) = text.lowercase().filter { it in 'a'..'z' }

    fun isValid(word: String, pinyin: String) =
        word.isNotBlank() && '\t' !in word && '\n' !in word && PINYIN.matches(pinyin)

    fun read(context: Context): List<ChineseWord> {
        val file = userFile(context)
        if(!file.isFile) return emptyList()
        return file.readLines().dropWhile { it != MARKER }.drop(1).mapNotNull { line ->
            line.split('\t').takeIf { it.size >= 2 }?.let { ChineseWord(it[0], it[1]) }
        }
    }

    /**
     * Saves [words]. Rime reads them when it starts, so a running Rime is restarted (about a second,
     * no deploy); one not running yet picks them up when Chinese is next typed.
     */
    suspend fun write(context: Context, words: List<ChineseWord>) {
        val wasReady = RimeIceSetup.state.value == RimeIceSetup.State.Ready
        RimeIceSetup.whileStopped(context) {
            val shipped = File(ChineseIME.getShared(context), FILE).takeIf { it.isFile }?.readText().orEmpty()
            userFile(context).writeText(buildString {
                append(shipped)
                if(isNotEmpty() && !endsWith('\n')) append('\n')
                appendLine(MARKER)
                words.forEach { appendLine("${it.word}\t${it.pinyin}") }
            })
        }
        if(wasReady) RimeIceSetup.prepareInBackground(context)
    }
}

object ChineseLearnedWords {
    /**
     * Deletes Rime's learned words (its user dictionaries and their sync snapshots). The deployed
     * build, the settings patch and the user's own words stay, so no new deploy is needed.
     */
    suspend fun forget(context: Context) {
        RimeIceSetup.whileStopped(context) {
            ChineseIME.getUser(context).walkBottomUp()
                .filter { it.name.endsWith(".userdb") || it.name.endsWith(".userdb.txt") }
                .forEach { it.deleteRecursively() }
        }
    }

    /**
     * Merges learned words another Rime exported ([snapshot]: its sync snapshot, `rime_ice.userdb.txt`)
     * into Rime's own, with Rime's sync (#11). The snapshot is removed after, so it is merged once.
     */
    suspend fun merge(context: Context, snapshot: InputStream): Boolean {
        val dir = File(ChineseIME.getUser(context), "sync/sebtype-import")
        return try {
            // Set up first, so a phone that hasn't typed Chinese yet has learned words to merge into.
            RimeIceSetup.ensureNow(context) && RimeIceSetup.syncUserData(context) {
                dir.mkdirs()
                File(dir, "rime_ice.userdb.txt").outputStream().use { snapshot.copyTo(it) }
            }
        } finally {
            dir.deleteRecursively()
        }
    }
}

/**
 * The user's own Rime word list (#11), the same file on the phone and the PCs: `sebtype_words.dict.yaml`
 * in the user dir, which the bundled pack `sebtype` imports (tools/rime-data/build.sh). Rime compiles
 * only that pack when it deploys.
 */
object ChineseWordList {
    private const val FILE = "sebtype_words.dict.yaml"
    private const val TABLE = "build/sebtype.table.bin"

    private fun file(context: Context) = File(ChineseIME.getUser(context), FILE)

    /** What the deploy depends on: a changed list makes [RimeIceSetup.ensure] deploy again. */
    fun stamp(context: Context) = file(context).let { if(it.isFile) "${it.length()} ${it.lastModified()}" else "" }

    /** Without a list Rime would keep using the table compiled from the last one. */
    fun dropStaleTable(context: Context) {
        if(!file(context).isFile) File(ChineseIME.getUser(context), TABLE).delete()
    }

    /** Replaces the list with [list]; Chinese deploys with it in the background. */
    suspend fun import(context: Context, list: InputStream) {
        RimeIceSetup.whileStopped(context) {
            file(context).outputStream().use { list.copyTo(it) }
        }
        RimeIceSetup.prepareInBackground(context)
    }
}
