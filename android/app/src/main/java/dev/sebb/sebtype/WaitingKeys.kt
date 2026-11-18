package dev.sebb.sebtype

import dev.sebb.sebtype.Layout.Code

/**
 * Keys and switches held back from the engine (#351), in the order they came, fed later in that order.
 * - Keys typed in 中文 while Rime starts wait for [ready].
 * - A switch is an edit that resets the engine and waits for it (the keyboard's finishTyping: a search opening
 *   or closing, paste, undo). While one runs, keys wait: sent then, they would reach the engine before its
 *   reset, which would drop them. A switch that comes while one runs or keys wait joins the queue too.
 * Until the queue is fed, keys after it wait too: none overtakes it.
 */
class WaitingKeys(
    /** Whether a waiting key can be fed now: not while 中文 is starting */
    private val ready: () -> Boolean,
    /** Types a key as it was tapped */
    private val feed: (Key) -> Unit,
    /** Keys fed that waited for Rime's start, not only for a switch: a count for the log, which tests read */
    private val fedForRime: (Int) -> Unit,
) {
    /** A key, with what the keyboard knew when it was tapped: [userShift], the user's Shift was on. */
    class Key(val code: Code, val text: String, val x: Int, val y: Int, val userShift: Boolean)

    private class Switch(val run: (done: () -> Unit) -> Unit)

    private val queue = ArrayDeque<Any>()
    private var switching = false
    private var feeding = false
    private var forRime = false

    fun hasKeys() = queue.any { it is Key }

    /** Whether the key waits; [chineseStarting]: the language is 中文 and Rime isn't ready yet. */
    fun hold(key: Key, chineseStarting: Boolean): Boolean {
        if (feeding) return false
        // Delete too waits in order: a Space before it may have committed a word it deletes from.
        if (key.code !in listOf(Code.TEXT, Code.SPACE, Code.ENTER, Code.DELETE)) return false
        if (queue.isEmpty() && !switching) {
            val letter = key.code == Code.TEXT && key.text.length == 1 && key.text[0].isLetter() && key.text[0].code < 0x80
            if (!chineseStarting || !letter) return false
        }
        queue += key
        if (chineseStarting) forRime = true
        return true
    }

    /** Runs [run] now, or after what is waiting; it calls done once the edit is made. */
    fun switch(run: (done: () -> Unit) -> Unit) {
        if (queue.isEmpty() && !switching) start(run) else queue += Switch(run)
    }

    /** Drops the waiting keys, as a new language, field or search drops a composition; the edits still run. */
    fun clear() {
        queue.removeAll { it is Key }
        forRime = false
        drain()
    }

    /** Feeds what waits, in order, up to a switch (which then runs) or a key that isn't [ready]. */
    fun drain() {
        var fed = 0
        while (!switching) {
            val next = queue.firstOrNull() ?: break
            if (next is Switch) {
                queue.removeFirst()
                start(next.run)
            } else {
                if (!ready()) break
                queue.removeFirst()
                feeding = true
                try {
                    feed(next as Key)
                } finally {
                    feeding = false
                }
                fed++
            }
        }
        if (fed > 0 && forRime) fedForRime(fed)
        if (!hasKeys()) forRime = false
    }

    private fun start(run: (done: () -> Unit) -> Unit) {
        switching = true
        run {
            switching = false
            drain()
        }
    }

    /** What the keys would leave as 中文's reading: letters add to it, Delete takes one off, Space, Enter and an edit end it. */
    fun reading() = queue.fold(StringBuilder()) { reading, entry ->
        when ((entry as? Key)?.code) {
            Code.TEXT -> reading.append((entry as Key).text)
            Code.DELETE -> if (reading.isNotEmpty()) reading.setLength(reading.length - 1)
            else -> reading.setLength(0)
        }
        reading
    }.toString()
}
