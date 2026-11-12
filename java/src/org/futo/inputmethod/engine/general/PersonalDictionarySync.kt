package org.futo.inputmethod.engine.general

import android.content.Context
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import org.futo.inputmethod.engine.GlobalIMEMessage
import org.futo.inputmethod.engine.IMEMessage
import org.futo.inputmethod.latin.uix.PersonalWord
import org.futo.inputmethod.latin.uix.UserDictionaryIO
import org.futo.inputmethod.latin.uix.settings.pages.pdict.JapanesePersonalWord
import org.futo.inputmethod.latin.uix.settings.pages.pdict.PosTypes
import org.futo.inputmethod.latin.uix.settings.pages.pdict.decodeJapanesePersonalWord
import org.futo.inputmethod.latin.uix.settings.pages.pdict.encode

/**
 * The personal dictionaries' part of the sync (#14). Each device's folder on the server holds its whole
 * Japanese dictionary in Mozc's own export format, which Mozc on a PC reads, and its other words
 * (English) in FUTO's `userdictionary.json` format. A device takes in only the words another device's
 * file gained since the copy it took last time, so a word deleted here doesn't come back from a device
 * that still has it, and nothing is ever deleted here.
 */
object PersonalDictionarySync {
    const val MOZC_FILE = "mozc_dictionary.txt"
    const val WORDS_FILE = "userdictionary.json"
    val FILES = setOf(MOZC_FILE, WORDS_FILE)

    private fun japanese(word: PersonalWord): JapanesePersonalWord? =
        if(word.locale?.substringBefore('_') == "ja") decodeJapanesePersonalWord(word) else null

    /** This device's files, from all of its personal words. Sorted, so an unchanged dictionary uploads nothing. */
    fun snapshots(words: List<PersonalWord>): Map<String, ByteArray> {
        val ja = words.mapNotNull(::japanese)
        val other = words.filter { japanese(it) == null }
        val mozc = ja.map { "${it.furigana}\t${it.output}\t${it.pos.text}\n" }.sorted().joinToString("")
        return mapOf(
            MOZC_FILE to mozc.toByteArray(),
            WORDS_FILE to Json.encodeToString(other.sortedWith(compareBy({ it.locale }, { it.word }, { it.shortcut })))
                .toByteArray(),
        )
    }

    /** `reading<TAB>word<TAB>part of speech[<TAB>comment]` lines; Mozc's comments have no place here. */
    private fun mozcWords(bytes: ByteArray): Set<PersonalWord> =
        String(bytes, Charsets.UTF_8).removePrefix("\uFEFF").lineSequence().mapNotNull { line ->
            val f = line.split('\t')
            if(f.size < 3 || f[0].isEmpty() || f[1].isEmpty() || line.startsWith("#")) return@mapNotNull null
            // An unknown part of speech (another IME's name for it) is Mozc's default, a noun.
            val pos = PosTypes.entries.find { it.text == f[2] } ?: PosTypes.NOUN
            JapanesePersonalWord(furigana = f[0], output = f[1], pos = pos).encode()
        }.toSet()

    private fun otherWords(bytes: ByteArray): Set<PersonalWord> = try {
        Json.decodeFromString<List<PersonalWord>>(String(bytes, Charsets.UTF_8)).toSet()
    } catch(_: IllegalArgumentException) {
        emptySet() // not a word list: nothing to take in
    }

    private fun words(name: String, bytes: ByteArray) =
        if(name == MOZC_FILE) mozcWords(bytes) else otherWords(bytes)

    private fun PersonalWord.key() = Triple(word, locale, shortcut)

    /** The words of another device's file [new] that its previous copy [old] didn't have and [own] lacks. */
    fun newWords(name: String, new: ByteArray, old: ByteArray?, own: List<PersonalWord>): List<PersonalWord> {
        val before = old?.let { words(name, it) }.orEmpty().map { it.key() }.toSet()
        val have = own.map { it.key() }.toSet()
        return words(name, new).filter { it.key() !in before && it.key() !in have }
    }

    fun snapshots(context: Context) = snapshots(UserDictionaryIO(context).get())

    /** Adds another device's new words to this phone's personal dictionary. */
    fun takeIn(context: Context, name: String, new: ByteArray, old: ByteArray?) {
        val io = UserDictionaryIO(context)
        val words = newWords(name, new, old, io.get())
        if(words.isEmpty()) return
        io.put(words)
        if(name == MOZC_FILE) GlobalIMEMessage.tryEmit(IMEMessage.ReloadPersonalDict)
    }
}
