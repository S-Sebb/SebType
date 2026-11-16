package dev.sebb.sebtype.core

/**
 * The sync's `mozc_dictionary.txt` with each word's last change and the deleted words (#273), for both phone
 * apps; sync-server/sebtype_sync.py does the same on the PCs, by the rules its "Deletions and edits" describes:
 *
 *     reading<TAB>word<TAB>part of speech<TAB>comment<TAB>time     a word, changed at time (ms since 1970)
 *     #-<TAB>reading<TAB>word<TAB><TAB><TAB>time                    a word deleted at time
 *
 * A word is its reading and spelling. A device keeps its own file as the record of what it had at the last
 * sync, dates what changed since ([stamp]), and takes in another device's file word by word, the newest change
 * winning ([merge]). A word without a time (an older client's, or one a device had at its first sync with this
 * version) comes in only when that device's file gained it since the copy taken last time, as before.
 */
object MozcWordSync {
    private const val DELETED = "#-\t"
    /** Mozc's part of speech for a name it doesn't know. */
    const val NOUN = "名詞"
    /** Mozc's parts of speech, by its `PosType` numbers, under the names its export uses. */
    val POS = listOf(
        "品詞なし", "名詞", "短縮よみ", "サジェストのみ", "固有名詞", "人名", "姓", "名", "組織", "地名", "名詞サ変", "名詞形動", "数",
        "アルファベット", "記号", "顔文字", "副詞", "連体詞", "接続詞", "感動詞", "接頭語", "助数詞", "接尾一般", "接尾人名", "接尾地名",
        "動詞ワ行五段", "動詞カ行五段", "動詞サ行五段", "動詞タ行五段", "動詞ナ行五段", "動詞マ行五段", "動詞ラ行五段", "動詞ガ行五段",
        "動詞バ行五段", "動詞ハ行四段", "動詞一段", "動詞カ変", "動詞サ変", "動詞ザ変", "動詞ラ変", "形容詞", "終助詞", "句読点", "独立語",
        "抑制単語",
    )

    data class Entry(
        val reading: String, val word: String, val pos: String,
        val comment: String = "", val time: Long = 0, val deleted: Boolean = false,
    ) {
        val key get() = reading to word

        /** Whether this change wins over [other]: the newer, an addition on a tie, then a fixed order. */
        fun beats(other: Entry) = compareValuesBy(this, other, { it.time }, { !it.deleted }, { it.pos }) > 0
    }

    fun parse(bytes: ByteArray): Map<Pair<String, String>, Entry> {
        val entries = HashMap<Pair<String, String>, Entry>()
        String(bytes, Charsets.UTF_8).removePrefix("\uFEFF").lineSequence().forEach { line ->
            val deleted = line.startsWith(DELETED)
            if (!deleted && line.startsWith("#")) return@forEach
            val f = line.removePrefix(DELETED).split('\t')
            if (f.size < 2 || f[0].isEmpty() || f[1].isEmpty() || (!deleted && f.size < 3)) return@forEach
            val column = { i: Int -> f.getOrElse(i) { "" } }
            val e = Entry(f[0], f[1], column(2).takeIf { it in POS } ?: NOUN, column(3),
                column(4).takeIf { it.all(Char::isDigit) }?.toLongOrNull() ?: 0, deleted)
            if (entries[e.key]?.let { e.beats(it) } != false) entries[e.key] = e
        }
        return entries
    }

    /** Sorted, so an unchanged dictionary uploads nothing. */
    fun format(entries: Collection<Entry>): ByteArray = entries.map { e ->
        if (e.deleted) DELETED + listOf(e.reading, e.word, "", "", e.time).joinToString("\t")
        else (listOf(e.reading, e.word, e.pos) + when {
            e.time != 0L -> listOf(e.comment, e.time.toString())
            e.comment.isNotEmpty() -> listOf(e.comment)
            else -> listOf()
        }).joinToString("\t")
    }.sorted().joinToString("") { "$it\n" }.toByteArray()

    /**
     * This device's file [own] (null before its first sync) brought up to date with its [words], dating what
     * changed since at [now]. A first sync dates nothing: what was deleted before it stays a local matter. A
     * change is dated after the one it replaces, even one from a device whose clock ran ahead, so the later
     * change wins everywhere.
     */
    fun stamp(own: Map<Pair<String, String>, Entry>?, words: List<Entry>, now: Long): MutableMap<Pair<String, String>, Entry> {
        val time = { e: Entry? -> if (own == null) 0 else maxOf(now, (e?.time ?: -1) + 1) }
        val out = HashMap(own.orEmpty())
        val have = words.associateBy { it.key }
        for ((key, w) in have) {
            val e = out[key]
            out[key] = when {
                e == null || e.deleted || e.pos != w.pos -> w.copy(time = time(e), deleted = false)
                else -> e.copy(comment = w.comment)
            }
        }
        for (entry in out.entries) entry.value.let { e ->
            if (!e.deleted && entry.key !in have) entry.setValue(Entry(e.reading, e.word, NOUN, "", time(e), true))
        }
        return out
    }

    /**
     * Takes another device's file [new], and the copy [old] taken of it last time, into this device's file
     * [own]; returns the changes that win, which this device's dictionary then gets.
     */
    fun merge(own: MutableMap<Pair<String, String>, Entry>, new: ByteArray, old: ByteArray?): List<Entry> {
        val before = old?.let(::parse).orEmpty()
        val changes = ArrayList<Entry>()
        for ((key, e) in parse(new)) {
            val mine = own[key]
            val wins = if (e.time != 0L) mine == null || e.beats(mine) else mine == null && key !in before && !e.deleted
            if (!wins) continue
            own[key] = e
            if (!(e.deleted && (mine == null || mine.deleted))) changes += e
        }
        return changes
    }
}
