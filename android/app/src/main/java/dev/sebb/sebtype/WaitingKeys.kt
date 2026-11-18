package dev.sebb.sebtype

import dev.sebb.sebtype.Layout.Code

/**
 * Keys held back from the engine (#351), fed to it in order later:
 * - typed in 中文 while Rime starts;
 * - typed while a switch that resets the engine (the keyboard's finishTyping: a search opening or closing,
 *   an edit action) still waits for it. A key sent then would reach the engine before the reset, which would
 *   drop it.
 * Until the queue is fed, keys after it wait too: none overtakes it.
 */
class WaitingKeys {
    class Key(val code: Code, val text: String, val x: Int, val y: Int)

    private val keys = ArrayList<Key>()
    private var switches = 0

    /** Whether a key waited for Rime's start, not only for a switch: for the log, which tests read. */
    var forRime = false
        private set

    fun isEmpty() = keys.isEmpty()

    /** Drops the keys, as a new language, field or search drops a composition. */
    fun clear() {
        keys.clear()
        forRime = false
    }

    fun switchStarted() {
        switches++
    }

    fun switchDone() {
        switches--
    }

    /** Whether the key waits; [chineseStarting]: the language is 中文 and Rime isn't ready yet. */
    fun hold(code: Code, text: String, x: Int, y: Int, chineseStarting: Boolean): Boolean {
        // Delete too waits in order: a Space before it may have committed a word it deletes from.
        if (code !in listOf(Code.TEXT, Code.SPACE, Code.ENTER, Code.DELETE)) return false
        if (keys.isEmpty() && switches == 0) {
            val letter = code == Code.TEXT && text.length == 1 && text[0].isLetter() && text[0].code < 0x80
            if (!chineseStarting || !letter) return false
        }
        keys += Key(code, text, x, y)
        if (chineseStarting) forRime = true
        return true
    }

    /** The keys to feed now, which leave the queue: none while a switch is pending or [ready] is false. */
    fun take(ready: Boolean): List<Key> {
        if (switches > 0 || !ready) return emptyList()
        return keys.toList().also { clear() }
    }

    /** What the keys would leave as 中文's reading: letters add to it, Delete takes one off, Space and Enter end it. */
    fun reading() = keys.fold(StringBuilder()) { reading, key ->
        when (key.code) {
            Code.TEXT -> reading.append(key.text)
            Code.DELETE -> if (reading.isNotEmpty()) reading.setLength(reading.length - 1)
            else -> reading.setLength(0)
        }
        reading
    }.toString()
}
