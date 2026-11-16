package dev.sebb.sebtype.next.data

import android.content.Context
import dev.sebb.sebtype.next.Engines
import java.io.File
import java.io.InputStream

/** One of the user's own 中文 words: the word and the pinyin that brings it up first. */
data class ChineseWord(val word: String, val pinyin: String)

/**
 * 中文's data in Rime's user dir (#41, #11), the same files on the phone and the PCs. Every change runs with Rime
 * stopped ([Engines.whileChineseStopped]) and [done] gets whether 中文 came back.
 */
object ChineseData {
    // rime-ice reads custom_phrase.txt from the user dir before the shared one, so the user's copy is
    // rime-ice's own file (as installed when the words last changed) and their words after this line.
    private const val PHRASES = "custom_phrase.txt"
    private const val MARKER = "# SebType: My words"
    // The user's own word list, which the bundled pack `sebtype` imports (data/rime/build.sh).
    private const val WORD_LIST = "sebtype_words.dict.yaml"
    private val PINYIN = Regex("[a-z]+")

    /** Lower-case letters only, so "Xiao Ming" and "xiao'ming" both type it. */
    fun normalizePinyin(text: String) = text.lowercase().filter { it in 'a'..'z' }

    fun isValid(word: String, pinyin: String) = word.isNotBlank() && '\t' !in word && '\n' !in word && PINYIN.matches(pinyin)

    fun myWords(context: Context): List<ChineseWord> {
        val file = File(Engines.userDir(context), PHRASES)
        if (!file.isFile) return emptyList()
        return file.readLines().dropWhile { it != MARKER }.drop(1).mapNotNull { line ->
            line.split('\t').takeIf { it.size >= 2 }?.let { ChineseWord(it[0], it[1]) }
        }
    }

    fun setMyWords(context: Context, words: List<ChineseWord>, done: (Boolean) -> Unit = {}) =
        Engines.whileChineseStopped(context, block = {
            val shipped = File(Engines.sharedDir(context), PHRASES).takeIf { it.isFile }?.readText().orEmpty()
            File(Engines.userDir(context), PHRASES).writeText(buildString {
                append(shipped)
                if (isNotEmpty() && !endsWith('\n')) append('\n')
                appendLine(MARKER)
                words.forEach { appendLine("${it.word}\t${it.pinyin}") }
            })
        }, done = done)

    /** Forgets what Rime learned (its user dictionaries and their sync snapshots); the user's own words stay. */
    fun forget(context: Context, done: (Boolean) -> Unit = {}) = Engines.whileChineseStopped(context, block = {
        Engines.userDir(context).walkBottomUp()
            .filter { it.name.endsWith(".userdb") || it.name.endsWith(".userdb.txt") }
            .forEach { it.deleteRecursively() }
    }, done = done)

    /**
     * Fuzzy pinyin's pairs: sounds that may be typed for one another, each as Rime spelling rules that add the
     * other spelling (Rime's `derive`, as in its documentation's fuzzy pinyin example).
     */
    enum class Fuzzy(val label: String, val rules: List<String>) {
        Z("z = zh", listOf("derive/^zh/z/", "derive/^z([^h])/zh$1/")),
        C("c = ch", listOf("derive/^ch/c/", "derive/^c([^h])/ch$1/")),
        S("s = sh", listOf("derive/^sh/s/", "derive/^s([^h])/sh$1/")),
        LN("l = n", listOf("derive/^n/l/", "derive/^l/n/")),
        FH("f = h", listOf("derive/^f/h/", "derive/^h/f/")),
        RL("r = l", listOf("derive/^r/l/", "derive/^l/r/")),
        KG("k = g", listOf("derive/^k/g/", "derive/^g/k/")),
        AN("an = ang", listOf("derive/ang$/an/", "derive/([^i])an$/$1ang/")),
        EN("en = eng", listOf("derive/eng$/en/", "derive/en$/eng/")),
        IN("in = ing", listOf("derive/ing$/in/", "derive/in$/ing/")),
        IAN("ian = iang", listOf("derive/iang$/ian/", "derive/ian$/iang/")),
        UAN("uan = uang", listOf("derive/uang$/uan/", "derive/uan$/uang/")),
    }

    // SebType's patch of rime-ice's schema; only fuzzy pinyin goes in it, so none is no file.
    private const val PATCH = "rime_ice.custom.yaml"

    fun patch(fuzzy: Set<Fuzzy>) = if (fuzzy.isEmpty()) "" else buildString {
        appendLine("patch:")
        // Appended: a bare speller/algebra would replace rime-ice's own rules, which give abbreviated pinyin.
        appendLine("  speller/algebra/+:")
        Fuzzy.entries.filter { it in fuzzy }.forEach { f -> f.rules.forEach { appendLine("    - $it") } }
    }

    /** Writes the schema patch for [fuzzy] if it changed; true when it did, and 中文 must compile it again. */
    fun writePatch(context: Context, fuzzy: Set<Fuzzy>): Boolean {
        val file = File(Engines.userDir(context), PATCH)
        val text = patch(fuzzy)
        if ((if (file.isFile) file.readText() else "") == text) return false
        if (text.isEmpty()) file.delete() else file.apply { parentFile!!.mkdirs() }.writeText(text)
        return true
    }

    fun setFuzzy(context: Context, fuzzy: Set<Fuzzy>, done: (Boolean) -> Unit = {}) =
        Engines.whileChineseStopped(context, redeploy = true, block = { writePatch(context, fuzzy) }, done = done)

    /** Replaces the user's word list (a `*.dict.yaml`); 中文 compiles it as it comes back. */
    fun importWordList(context: Context, list: InputStream, done: (Boolean) -> Unit = {}) {
        val bytes = list.readBytes()
        Engines.whileChineseStopped(context, redeploy = true, block = {
            File(Engines.userDir(context), WORD_LIST).writeBytes(bytes)
        }, done = done)
    }

    /**
     * Merges learned words another Rime exported (its sync snapshot, `rime_ice.userdb.txt`) into Rime's own,
     * through Rime's sync; the snapshot is removed after, so it is merged once. Blocks.
     */
    fun importLearnedWords(context: Context, snapshot: InputStream): Boolean {
        val dir = File(Engines.userDir(context), "sync/sebtype-import")
        return try {
            dir.mkdirs()
            File(dir, "rime_ice.userdb.txt").outputStream().use { snapshot.copyTo(it) }
            // Set up first (queued before the sync), so a phone that never typed 中文 has learned words to merge into.
            Engines.prepareChinese(context)
            Engines.syncChinese(context)
        } finally {
            dir.deleteRecursively()
        }
    }
}
