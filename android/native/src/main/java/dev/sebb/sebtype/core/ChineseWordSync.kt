package dev.sebb.sebtype.core

import java.io.File
import java.io.IOException

/**
 * The sync's record of 中文's My words (#272), for both phone apps; sync-server/sebtype_sync.py does the same on
 * the PCs. A word is its pinyin and spelling, and the file and its rules are [MozcWordSync]'s, as
 * `pinyin<TAB>word<TAB>名詞[<TAB><TAB>time]` lines and `#-` lines for deleted words: the part of speech only
 * fills Mozc's column. The file is named like Rime's snapshots, so servers and clients from before #272 store
 * and pass it on unchanged; Rime takes in only its own user dictionaries' snapshots, so it never reads it.
 */
object ChineseWordSync {
    const val FILE = "zh_my_words.userdb.txt"

    /** A word as (pinyin, word). */
    private fun entry(word: Pair<String, String>) = MozcWordSync.Entry(word.first, word.second, MozcWordSync.NOUN)

    /**
     * This device's file [own] brought up to date with its My words [words] (null: never saved, so none to tell,
     * rather than all deleted), and saved.
     */
    fun ownEntries(own: File, words: List<Pair<String, String>>?, now: Long = System.currentTimeMillis()): MutableMap<Pair<String, String>, MozcWordSync.Entry> {
        val before = own.takeIf { it.isFile }?.readBytes()?.let(MozcWordSync::parse)
        val entries = if (words == null) HashMap(before.orEmpty()) else MozcWordSync.stamp(before, words.map(::entry), now)
        return entries.also { save(own, it) }
    }

    private fun save(own: File, entries: Map<Pair<String, String>, MozcWordSync.Entry>) = replace(own, MozcWordSync.format(entries.values))

    /**
     * Writes [file] whole or not at all: [bytes] go to a file beside it, renamed over it. Written in place, a
     * write cut off would leave My words looking complete with words missing, which the next sync would send
     * everywhere as deletions (#272).
     */
    fun replace(file: File, bytes: ByteArray) {
        file.parentFile!!.mkdirs()
        val tmp = File(file.path + ".tmp")
        tmp.writeBytes(bytes)
        if (!tmp.renameTo(file)) throw IOException("can't save ${file.name}")
    }

    /**
     * What another device's file changes here: [words] is the new My words (null when nothing changed), to save
     * first; then [save] keeps the merged file, so a sync cut off in between takes the file in again.
     */
    class Changes(val words: List<Pair<String, String>>?, private val own: File, private val merged: Map<Pair<String, String>, MozcWordSync.Entry>) {
        fun save() = ChineseWordSync.save(own, merged)
    }

    /** Takes another device's file [new] (and the copy [old] taken last time) into this device's [own] and [have]. */
    fun changes(own: File, have: List<Pair<String, String>>?, new: ByteArray, old: ByteArray?): Changes {
        val entries = ownEntries(own, have)
        val changes = MozcWordSync.merge(entries, new, old)
        if (changes.isEmpty()) return Changes(null, own, entries)
        val gone = changes.map { it.key }.toSet()
        return Changes(have.orEmpty().filter { it !in gone } + changes.filter { !it.deleted }.map { it.key }, own, entries)
    }

    /**
     * A client from before #272 kept other devices' files in the sync folder [sync] as Rime snapshots without
     * taking their words in, so they aren't what this device took in last time. Deleted before this device has
     * its own file [own], so a first sync cut off after one device's file still takes in the others' later.
     */
    fun dropOldCopies(own: File, sync: File) {
        if (!own.isFile) sync.listFiles().orEmpty().forEach { File(it, FILE).delete() }
    }
}
