package dev.sebb.sebtype

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
