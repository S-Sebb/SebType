package dev.sebb.sebtype.next.sync

import android.content.Context
import dev.sebb.sebtype.next.data.MozcPos
import dev.sebb.sebtype.next.data.PersonalWord
import dev.sebb.sebtype.next.data.PersonalWords
import org.json.JSONException

/**
 * The personal dictionaries' part of the sync (#14). Each device's folder on the server holds its whole
 * 日本語 dictionary in Mozc's own export format, which Mozc on a PC reads, and its other words (English) in
 * `userdictionary.json`. A device takes in only the words another device's file gained since the copy it took
 * last time, so a word deleted here doesn't come back from a device that still has it, and nothing is ever
 * deleted here.
 */
object PersonalDictionarySync {
    const val MOZC_FILE = "mozc_dictionary.txt"
    const val WORDS_FILE = "userdictionary.json"
    val FILES = setOf(MOZC_FILE, WORDS_FILE)

    /** This device's files, from all of its personal words. Sorted, so an unchanged dictionary uploads nothing. */
    fun snapshots(words: List<PersonalWord>): Map<String, ByteArray> {
        val (ja, other) = words.partition { it.japanese }
        val mozc = ja.map { "${it.reading}\t${it.word}\t${MozcPos.name(it.pos)}\n" }.sorted().joinToString("")
        return mapOf(
            MOZC_FILE to mozc.toByteArray(),
            WORDS_FILE to PersonalWord.json(other.sortedWith(compareBy({ it.locale }, { it.word }, { it.shortcut }))).toByteArray(),
        )
    }

    /** `reading<TAB>word<TAB>part of speech[<TAB>comment]` lines; Mozc's comments have no place here. */
    private fun mozcWords(bytes: ByteArray): Set<PersonalWord> =
        String(bytes, Charsets.UTF_8).removePrefix("\uFEFF").lineSequence().mapNotNull { line ->
            val f = line.split('\t')
            if (f.size < 3 || f[0].isEmpty() || f[1].isEmpty() || line.startsWith("#")) null
            else PersonalWord.japanese(f[0], f[1], MozcPos.of(f[2]))
        }.toSet()

    private fun otherWords(bytes: ByteArray): Set<PersonalWord> = try {
        PersonalWord.list(String(bytes, Charsets.UTF_8)).toSet()
    } catch (_: JSONException) {
        emptySet() // not a word list: nothing to take in
    }

    private fun words(name: String, bytes: ByteArray) = if (name == MOZC_FILE) mozcWords(bytes) else otherWords(bytes)

    private fun PersonalWord.key() = Triple(word, locale, shortcut)

    /** The words of another device's file [new] that its previous copy [old] didn't have and [own] lacks. */
    fun newWords(name: String, new: ByteArray, old: ByteArray?, own: List<PersonalWord>): List<PersonalWord> {
        val before = old?.let { words(name, it) }.orEmpty().map { it.key() }.toSet()
        val have = own.map { it.key() }.toSet()
        return words(name, new).filter { it.key() !in before && it.key() !in have }
    }

    fun snapshots(context: Context) = snapshots(PersonalWords.all(context))

    /** Adds another device's new words to this phone's personal dictionary. */
    fun takeIn(context: Context, name: String, new: ByteArray, old: ByteArray?) {
        val words = newWords(name, new, old, PersonalWords.all(context))
        if (words.isNotEmpty()) PersonalWords.add(context, words)
    }
}
