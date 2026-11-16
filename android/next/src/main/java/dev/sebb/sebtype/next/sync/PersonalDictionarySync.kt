package dev.sebb.sebtype.next.sync

import android.content.Context
import dev.sebb.sebtype.core.MozcWordSync
import dev.sebb.sebtype.next.data.MozcPos
import dev.sebb.sebtype.next.data.PersonalWord
import dev.sebb.sebtype.next.data.PersonalWords
import org.json.JSONException
import java.io.File
import java.io.IOException

/**
 * The personal dictionaries' part of the sync (#14). Each device's folder on the server holds its whole
 * 日本語 dictionary in Mozc's own export format, which Mozc on a PC reads, with each word's last change and the
 * words deleted on it ([MozcWordSync], #273), and its other words (English) in `userdictionary.json`. A 日本語
 * word's newest change wins, a deletion too. Of the other words a device takes in only those another device's
 * file gained since the copy it took last time, so a word deleted here doesn't come back from a device that
 * still has it, and nothing of them is deleted here.
 */
object PersonalDictionarySync {
    const val MOZC_FILE = "mozc_dictionary.txt"
    const val WORDS_FILE = "userdictionary.json"
    val FILES = setOf(MOZC_FILE, WORDS_FILE)

    private fun PersonalWord.entry() = MozcWordSync.Entry(reading, word, MozcPos.name(pos))

    /** This phone's 日本語 file, kept in [own], brought up to date with its [words]. */
    fun ownMozc(own: File, words: List<PersonalWord>, now: Long = System.currentTimeMillis()): MutableMap<Pair<String, String>, MozcWordSync.Entry> {
        val before = own.takeIf { it.isFile }?.readBytes()?.let(MozcWordSync::parse)
        return MozcWordSync.stamp(before, words.filter { it.japanese }.map { it.entry() }, now).also { save(own, it) }
    }

    private fun save(own: File, entries: Map<Pair<String, String>, MozcWordSync.Entry>) {
        own.parentFile!!.mkdirs()
        val tmp = File(own.path + ".tmp")
        tmp.writeBytes(MozcWordSync.format(entries.values))
        if (!tmp.renameTo(own)) throw IOException("can't save the sync's 日本語 words")
    }

    /** This device's other words' file. Sorted, so an unchanged dictionary uploads nothing. */
    fun wordsFile(words: List<PersonalWord>): ByteArray =
        PersonalWord.json(words.filter { !it.japanese }.sortedWith(compareBy({ it.locale }, { it.word }, { it.shortcut }))).toByteArray()

    private fun otherWords(bytes: ByteArray): Set<PersonalWord> = try {
        PersonalWord.list(String(bytes, Charsets.UTF_8)).toSet()
    } catch (_: JSONException) {
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
     * What another device's 日本語 file changes here: [removed] and [added] go to the personal dictionary first,
     * then [save] keeps the merged file. Saved before, a sync cut off in between would take the words not yet
     * in the dictionary for ones deleted here.
     */
    class JapaneseChanges(
        val removed: List<PersonalWord>, val added: List<PersonalWord>,
        private val own: File, private val merged: Map<Pair<String, String>, MozcWordSync.Entry>,
    ) {
        fun save() = PersonalDictionarySync.save(own, merged)
    }

    /** Takes another device's 日本語 file into this phone's file [own] and its words [have]. */
    fun japaneseChanges(own: File, have: List<PersonalWord>, new: ByteArray, old: ByteArray?): JapaneseChanges {
        val entries = ownMozc(own, have)
        val changes = MozcWordSync.merge(entries, new, old)
        val keys = changes.map { it.key }.toSet()
        return JapaneseChanges(have.filter { it.japanese && it.reading to it.word in keys },
            changes.filter { !it.deleted }.map { PersonalWord.japanese(it.reading, it.word, MozcPos.of(it.pos)) }, own, entries)
    }

    private fun ownFile(context: Context) = File(context.noBackupFilesDir, "sync/$MOZC_FILE")

    fun snapshots(context: Context): Map<String, ByteArray> {
        val words = PersonalWords.all(context)
        return mapOf(MOZC_FILE to MozcWordSync.format(ownMozc(ownFile(context), words).values), WORDS_FILE to wordsFile(words))
    }

    /** Takes another device's changes into this phone's personal dictionary. */
    fun takeIn(context: Context, name: String, new: ByteArray, old: ByteArray?) {
        if (name != MOZC_FILE) {
            newWords(new, old, PersonalWords.all(context)).takeIf { it.isNotEmpty() }?.let { PersonalWords.add(context, it) }
            return
        }
        val changes = japaneseChanges(ownFile(context), PersonalWords.all(context), new, old)
        if (changes.removed.isNotEmpty()) PersonalWords.delete(context, *changes.removed.toTypedArray())
        if (changes.added.isNotEmpty()) PersonalWords.add(context, changes.added)
        changes.save()
    }
}
