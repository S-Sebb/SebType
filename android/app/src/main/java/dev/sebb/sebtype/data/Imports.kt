package dev.sebb.sebtype.data

import org.json.JSONException

/**
 * What Settings › Sync & backup › Import takes (#11, #34), told apart by the file's first bytes: a settings
 * backup, or the PCs' personal data, each for one language.
 */
sealed interface Import {
    /** The language the file is for: zh, ja or en, shown as the import screen's row. */
    val language: String

    data object Backup : Import { override val language = "" }
    data object RimeWordList : Import { override val language = "zh" }
    data object RimeLearnedWords : Import { override val language = "zh" }
    data object MozcDictionary : Import { override val language = "ja" }
    data class EnglishWords(val words: List<PersonalWord>) : Import { override val language = "en" }

    companion object {
        // A file's first lines are enough to tell its kind; what is read for that stays small.
        private const val HEAD_BYTES = 64 * 1024
        private const val WORDS_MAX_BYTES = 4 * 1024 * 1024
        /** As much of a file as [of] needs: more is a file too big for a word list. */
        const val HEAD_MAX = WORDS_MAX_BYTES

        fun of(bytes: ByteArray): Import? {
            if (bytes.size >= 4 && bytes[0] == 'P'.code.toByte() && bytes[1] == 'K'.code.toByte()) return Backup
            val lines = lines(bytes.copyOf(minOf(bytes.size, HEAD_BYTES)), cut = bytes.size > HEAD_BYTES)
            return when {
                rimeLearnedWords(lines) -> RimeLearnedWords
                rimeWordList(lines) -> RimeWordList
                msIme(lines) || mozc(lines) -> MozcDictionary
                else -> englishWords(bytes)?.let { EnglishWords(it) }
            }
        }

        /** The lines of [bytes], without one cut off at its end. */
        private fun lines(bytes: ByteArray, cut: Boolean): List<String> {
            val lines = String(bytes, Charsets.UTF_8).removePrefix("\uFEFF").lines()
            return if (cut) lines.dropLast(1) else lines
        }

        /** A Rime sync snapshot (`rime_ice.userdb.txt`) of rime-ice's learned words */
        private fun rimeLearnedWords(lines: List<String>) = lines.firstOrNull() == "# Rime user dictionary" &&
            lines.takeWhile { it.startsWith("#") }.any { it == "#@/db_name\trime_ice" }

        /** A Rime word list (`*.dict.yaml`) with a name and a version in its header */
        private fun rimeWordList(lines: List<String>): Boolean {
            val end = lines.indexOfFirst { it.trimEnd() == "..." }.takeIf { it >= 0 } ?: return false
            val header = lines.take(end).map { it.trimEnd() }
            fun value(key: String) = header.firstOrNull { it.startsWith("$key:") }?.substringAfter(':')?.trim()?.trim('"', '\'')
            return !value("name").isNullOrEmpty() && value("version") != null
        }

        /** Microsoft IME's dictionary tool export, which Mozc imports too */
        private fun msIme(lines: List<String>) = lines.firstOrNull()?.startsWith("!Microsoft IME Dictionary Tool") == true

        private fun isKana(c: Char) = Character.UnicodeBlock.of(c).let {
            it == Character.UnicodeBlock.HIRAGANA || it == Character.UnicodeBlock.KATAKANA
        } || c in "ー・"

        /** Mozc's own export: `reading<TAB>word<TAB>part of speech[<TAB>comment]` lines with no header. */
        private fun mozc(lines: List<String>): Boolean {
            val entries = lines.filter { it.isNotBlank() && !it.startsWith("#") }.take(20).ifEmpty { return false }
            return entries.all { line ->
                val f = line.split('\t')
                f.size >= 3 && f[0].isNotEmpty() && f[0].all(::isKana) && f[1].isNotEmpty()
            }
        }

        /** A personal dictionary (`userdictionary.json` of today's backups), English words only. */
        private fun englishWords(bytes: ByteArray): List<PersonalWord>? {
            if (bytes.size >= WORDS_MAX_BYTES) return null
            val text = String(bytes, Charsets.UTF_8).removePrefix("\uFEFF").trim()
            if (!text.startsWith("[")) return null
            return try {
                PersonalWord.list(text).filter { !it.japanese }.ifEmpty { null }
            } catch (_: JSONException) {
                null
            }
        }
    }
}
