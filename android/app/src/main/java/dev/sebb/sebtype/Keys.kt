package dev.sebb.sebtype

import dev.sebb.sebtype.core.NativeState

/**
 * English's results and the keys they are for (#280). The engine works ahead of the field, and a result is
 * written where the cursor is when it comes. Once the field changed other than by the keys (the user moved
 * the cursor, the app edited, the keys went to a search), the engine reads it again ([reread]): results asked
 * for before that read are dropped, and the keys whose results were still to come go to the engine again
 * behind it. So every key typed is written once, in the order typed, at the cursor as it is then.
 */
class Keys {
    private var reads = 0
    private val typed = ArrayList<Key>()

    /** An engine result asked for now: it may write to the field until the engine reads it again */
    inner class Asked {
        internal val reads = this@Keys.reads
    }
    fun ask() = Asked()
    fun fresh(asked: Asked) = asked.reads == reads

    /** A key typed: [send] posts it to the engine and calls [Key.done] once its result came, shown or dropped. */
    inner class Key(internal val send: (Key) -> Unit) {
        fun done() { typed.remove(this) }
    }
    fun type(send: (Key) -> Unit) {
        val key = Key(send)
        typed += key
        send(key)
    }

    /** The engine reads the field again ([read]); the keys still to come follow it, sent again. */
    fun reread(read: () -> Unit) {
        reads++
        read()
        val again = typed.toList()
        typed.clear()
        again.forEach { type(it.send) }
    }

    /** Another field: results and keys for the last one are dropped. */
    fun forget() {
        reads++
        typed.clear()
    }
}

/**
 * The text before the cursor as the engine's results so far leave it, kept on the engine thread, so an English
 * letter typed ahead of the field gets its capital by the text it will follow (#241). Every result counts: a
 * picked suggestion's commit left out made the next word's first letter a capital (#453).
 */
class EngineText {
    private val before = StringBuilder()
    /** What the engine has typed after the last result, in the field's composing text */
    var preedit = ""
        private set
    val composing get() = preedit.isNotEmpty()

    /** The field's text before what the engine has typed, as read */
    fun read(text: String) {
        before.setLength(0)
        before.append(text)
    }

    /** Another field: [text] before the cursor, nothing typed */
    fun enter(text: String) {
        read(text)
        preedit = ""
    }

    /** A result, as the field takes it: a word it reopened becomes what is typed, then its deletion and commit */
    fun record(st: NativeState) {
        if (st.recompose) drop(st.composeBefore)
        drop(st.deleteBefore)
        before.append(st.commit)
        preedit = st.preedit
    }

    /** A key the engine didn't take, done in the field: [text] typed, or Delete's character (null) gone */
    fun typed(text: String?) {
        if (text != null) before.append(text) else drop(1)
    }

    private fun drop(n: Int) = before.setLength(maxOf(0, before.length - n))

    /** The text a letter typed now follows */
    override fun toString() = "$before$preedit"
}
