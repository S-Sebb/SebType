package org.futo.inputmethod.latin.uix

import kotlinx.serialization.json.Json
import java.io.InputStream
import java.util.Locale

/**
 * SebType's personal data import (#11): the files Settings › Sync & backup › Import recognises besides
 * a settings backup and FUTO's Japanese dictionary formats, each told apart by its first lines.
 */
object PersonalDataImport {
    // A file's first lines are enough to tell its kind; what is read for that stays small.
    private const val HEAD_BYTES = 64 * 1024
    private const val PERSONAL_WORDS_MAX_BYTES = 4 * 1024 * 1024

    /** The first lines, without one cut off at [HEAD_BYTES]. */
    private fun head(input: InputStream) = lines(input.readNBytesCompat(HEAD_BYTES))

    private fun lines(bytes: ByteArray): List<String> {
        val lines = String(bytes, Charsets.UTF_8).removePrefix("\uFEFF").lines()
        return if(bytes.size == HEAD_BYTES) lines.dropLast(1) else lines
    }

    /** A Rime sync snapshot (`<dictionary>.userdb.txt`) of rime_ice's learned words: its dictionary's name, or null. */
    fun rimeLearnedWords(input: InputStream): String? {
        val lines = head(input)
        if(lines.firstOrNull() != "# Rime user dictionary") return null
        return lines.takeWhile { it.startsWith("#") }
            .firstNotNullOfOrNull { it.removePrefix("#@/db_name\t").takeIf { name -> name != it } }
            ?.takeIf { it == "rime_ice" }
    }

    /** A Rime word list (`*.dict.yaml`): its name from the header, or null. */
    fun rimeWordList(input: InputStream): String? {
        val lines = head(input)
        val end = lines.indexOfFirst { it.trimEnd() == "..." }.takeIf { it >= 0 } ?: return null
        val header = lines.take(end)
        fun value(key: String) = header.firstNotNullOfOrNull { line ->
            line.trimEnd().removePrefix("$key:").takeIf { it != line.trimEnd() }?.trim()?.trim('"', '\'')
        }
        val name = value("name")?.takeIf { it.isNotEmpty() } ?: return null
        return name.takeIf { value("version") != null }
    }

    private fun isKana(c: Char) = Character.UnicodeBlock.of(c).let {
        it == Character.UnicodeBlock.HIRAGANA || it == Character.UnicodeBlock.KATAKANA
    } || c in "ー・"

    /**
     * Mozc's own dictionary export (its dictionary tool's "Export"): `reading<TAB>word<TAB>part of
     * speech[<TAB>comment]` lines with no header, in UTF-8. Mozc reads it as it is.
     */
    fun mozcDictionary(input: InputStream): DetectedUserDictFile? {
        val bytes = input.readNBytesCompat(HEAD_BYTES)
        val entries = lines(bytes).filter { it.isNotBlank() && !it.startsWith("#") }.take(20).ifEmpty { return null }
        val valid = entries.all { line ->
            val fields = line.split('\t')
            fields.size >= 3 && fields[0].isNotEmpty() && fields[0].all(::isKana) && fields[1].isNotEmpty()
        }
        // The copy for Mozc is read from the start, so a UTF-8 byte order mark is skipped there.
        val bom = if(bytes.take(3) == listOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte())) 3 else 0
        return if(valid) DetectedUserDictFile("mozc", "Mozc", Locale.JAPANESE, Charsets.UTF_8, bom) else null
    }

    /** FUTO's personal dictionary (`userdictionary.json` in a settings backup), or null. */
    fun personalWords(input: InputStream): List<PersonalWord>? {
        // A personal dictionary is far smaller; a larger file isn't one.
        val bytes = input.readNBytesCompat(PERSONAL_WORDS_MAX_BYTES).takeIf { it.size < PERSONAL_WORDS_MAX_BYTES } ?: return null
        val text = String(bytes, Charsets.UTF_8).removePrefix("\uFEFF").trim()
        if(!text.startsWith("[")) return null
        return try {
            Json.decodeFromString<List<PersonalWord>>(text).ifEmpty { null }
        } catch(_: IllegalArgumentException) {
            null
        }
    }

    private fun InputStream.readNBytesCompat(n: Int): ByteArray {
        val buffer = ByteArray(n)
        var read = 0
        while(read < n) {
            val count = read(buffer, read, n - read)
            if(count < 0) break
            read += count
        }
        return buffer.copyOf(read)
    }
}
