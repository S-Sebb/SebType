package dev.sebb.sebtype.sync

import android.content.Context
import android.provider.UserDictionary
import dev.sebb.sebtype.core.MozcWordSync
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
import java.io.File
import java.io.IOException

/**
 * The personal dictionaries' part of the sync (#14). Each device's folder on the server holds its whole
 * Japanese dictionary in Mozc's own export format, which Mozc on a PC reads, with each word's last change and
 * the words deleted on it ([MozcWordSync], #273), and its other words (English) in FUTO's `userdictionary.json`
 * format. A Japanese word's newest change wins, a deletion too. Of the other words a device takes in only those
 * another device's file gained since the copy it took last time, so a word deleted here doesn't come back from
 * a device that still has it, and nothing of them is deleted here.
 */
object PersonalDictionarySync {
    const val MOZC_FILE = "mozc_dictionary.txt"
    const val WORDS_FILE = "userdictionary.json"
    val FILES = setOf(MOZC_FILE, WORDS_FILE)

    private fun japanese(word: PersonalWord): JapanesePersonalWord? =
        if(word.locale?.substringBefore('_') == "ja") decodeJapanesePersonalWord(word) else null

    private fun JapanesePersonalWord.entry() = MozcWordSync.Entry(furigana, output, pos.text)

    private fun MozcWordSync.Entry.word() =
        JapanesePersonalWord(furigana = reading, output = word, pos = PosTypes.entries.find { it.text == pos } ?: PosTypes.NOUN).encode()

    /** This phone's Japanese file, kept in [own], brought up to date with its [words]. */
    fun ownMozc(own: File, words: List<PersonalWord>, now: Long = System.currentTimeMillis()): MutableMap<Pair<String, String>, MozcWordSync.Entry> {
        val before = own.takeIf { it.isFile }?.readBytes()?.let(MozcWordSync::parse)
        return MozcWordSync.stamp(before, words.mapNotNull { japanese(it)?.entry() }, now).also { save(own, it) }
    }

    private fun save(own: File, entries: Map<Pair<String, String>, MozcWordSync.Entry>) {
        own.parentFile!!.mkdirs()
        val tmp = File(own.path + ".tmp")
        tmp.writeBytes(MozcWordSync.format(entries.values))
        if(!tmp.renameTo(own)) throw IOException("can't save the sync's Japanese words")
    }

    /** This device's other words' file. Sorted, so an unchanged dictionary uploads nothing. */
    fun wordsFile(words: List<PersonalWord>): ByteArray =
        Json.encodeToString(words.filter { japanese(it) == null }.sortedWith(compareBy({ it.locale }, { it.word }, { it.shortcut })))
            .toByteArray()

    private fun otherWords(bytes: ByteArray): Set<PersonalWord> = try {
        Json.decodeFromString<List<PersonalWord>>(String(bytes, Charsets.UTF_8)).toSet()
    } catch(_: IllegalArgumentException) {
        emptySet() // not a word list: nothing to take in
    }

    private fun PersonalWord.key() = Triple(word, locale, shortcut)

    /** The words of another device's other words' file [new] that its previous copy [old] didn't have and [own] lacks. */
    fun newWords(new: ByteArray, old: ByteArray?, own: List<PersonalWord>): List<PersonalWord> {
        val before = old?.let { otherWords(it) }.orEmpty().map { it.key() }.toSet()
        val have = own.map { it.key() }.toSet()
        return otherWords(new).filter { it.key() !in before && it.key() !in have }
    }

    /**
     * What another device's Japanese file changes here: [removed] and [added] go to the personal dictionary first,
     * then [save] keeps the merged file. Saved before, a sync cut off in between would take the words not yet
     * in the dictionary for ones deleted here.
     */
    class JapaneseChanges(
        val removed: List<PersonalWord>, val added: List<PersonalWord>,
        private val own: File, private val merged: Map<Pair<String, String>, MozcWordSync.Entry>,
    ) {
        fun save() = PersonalDictionarySync.save(own, merged)
    }

    /** Takes another device's Japanese file into this phone's file [own] and its words [have]. */
    fun japaneseChanges(own: File, have: List<PersonalWord>, new: ByteArray, old: ByteArray?): JapaneseChanges {
        val entries = ownMozc(own, have)
        val changes = MozcWordSync.merge(entries, new, old)
        val keys = changes.map { it.key }.toSet()
        return JapaneseChanges(have.filter { japanese(it)?.let { j -> j.furigana to j.output } in keys },
            changes.filter { !it.deleted }.map { it.word() }, own, entries)
    }

    private fun ownFile(context: Context) = File(context.noBackupFilesDir, "sync/$MOZC_FILE")

    fun snapshots(context: Context): Map<String, ByteArray> {
        val words = UserDictionaryIO(context).get()
        return mapOf(MOZC_FILE to MozcWordSync.format(ownMozc(ownFile(context), words).values), WORDS_FILE to wordsFile(words))
    }

    /** Takes another device's changes into this phone's personal dictionary. */
    fun takeIn(context: Context, name: String, new: ByteArray, old: ByteArray?) {
        val io = UserDictionaryIO(context)
        if(name != MOZC_FILE) {
            newWords(new, old, io.get()).takeIf { it.isNotEmpty() }?.let { io.put(it) }
            return
        }
        val changes = japaneseChanges(ownFile(context), io.get(), new, old)
        if(changes.removed.isNotEmpty() || changes.added.isNotEmpty()) {
            // By reading too: UserDictionaryIO.remove would take every Japanese word spelled the same.
            changes.removed.forEach {
                context.contentResolver.delete(UserDictionary.Words.CONTENT_URI,
                    "${UserDictionary.Words.WORD}=? AND ${UserDictionary.Words.SHORTCUT}=?", arrayOf(it.word, it.shortcut))
            }
            io.put(changes.added)
            GlobalIMEMessage.tryEmit(IMEMessage.ReloadPersonalDict)
        }
        changes.save()
    }
}
