package dev.sebb.sebtype

import dev.sebb.sebtype.Layout.Code

/**
 * The keyboard's one serial dispatcher for input (#351). THE RULE: every input action goes through it,
 * keys and the globe ([hold]), edits that wait for the engine ([switch]) and everything else that reaches the
 * engine or the field ([run]: chips, gestures, candidates, the action bar's language, pastes from a search…). While anything is queued or an edit is
 * pending, an action is appended; otherwise it runs at once, as if there were no queue. A new action that
 * skips it can overtake keys still waiting and land in the wrong order.
 *
 * - Keys typed in 中文 while Rime starts wait for [ready]; what comes after them waits too.
 * - An edit (the keyboard's finishTyping: paste, undo, a search opening or closing) resets the engine and
 *   waits for it; what comes meanwhile waits, since the reset would drop it.
 * - A new field or search, or the keyboard closing, [cancel]s everything queued, edits included, and an edit already started
 *   does nothing when it finishes: nothing lands in a field that was left.
 */
class WaitingKeys(
    /** Whether a waiting key can be fed now: not while 中文 is starting */
    private val ready: () -> Boolean,
    /** Types a key as it was tapped */
    private val feed: (Key) -> Unit,
    /** Keys fed that waited for Rime's start, not only behind an edit: a count for the log, which tests read */
    private val fedForRime: (Int) -> Unit,
) {
    /** A key, with what the keyboard knew when it was tapped: [userShift], the user's Shift was on. */
    class Key(val code: Code, val text: String, val x: Int, val y: Int, val userShift: Boolean)

    private class Action(val run: () -> Unit)

    private class Switch(val run: (finish: (edit: () -> Unit) -> Unit) -> Unit)

    private val queue = ArrayDeque<Any>()
    private var switching = false
    // An action being fed runs what it starts at once: that is its own work, not a new action.
    private var feeding = false
    private var generation = 0
    private var forRime = false

    private val idle get() = feeding || (queue.isEmpty() && !switching)

    fun hasKeys() = queue.any { it is Key }

    /** Whether the key waits; [chineseStarting]: the language is 中文 and Rime isn't ready yet. */
    fun hold(key: Key, chineseStarting: Boolean): Boolean {
        if (feeding) return false
        // Delete too waits in order: a Space before it may have committed a word it deletes from. The globe
        // waits its turn: what was typed before it goes in, in the language it was typed in.
        if (key.code !in listOf(Code.TEXT, Code.SPACE, Code.ENTER, Code.DELETE, Code.GLOBE)) return false
        if (queue.isEmpty() && !switching) {
            val letter = key.code == Code.TEXT && key.text.length == 1 && key.text[0].isLetter() && key.text[0].code < 0x80
            if (!chineseStarting || !letter) return false
        }
        queue += key
        if (chineseStarting) forRime = true
        return true
    }

    /** Runs [action] now, or after what is waiting. */
    fun run(action: () -> Unit) {
        if (idle) action() else queue += Action(action)
    }

    /**
     * An edit that waits for the engine: [run] now or after what is waiting. It calls finish with the edit
     * itself once the engine has answered; the edit is dropped if the field changed meanwhile.
     */
    fun switch(run: (finish: (edit: () -> Unit) -> Unit) -> Unit) {
        if (idle) start(run) else queue += Switch(run)
    }

    /** A new field or search, or the keyboard closing: everything queued goes, and an edit under way lands nowhere. */
    fun cancel() {
        queue.clear()
        switching = false
        generation++
        forRime = false
    }

    /** Feeds what waits, in order, up to an edit (which then starts) or a key that isn't [ready]. */
    fun drain() {
        var fed = 0
        while (!switching) {
            val next = queue.firstOrNull() ?: break
            if (next is Key && !ready()) break
            queue.removeFirst()
            if (next is Switch) {
                start(next.run)
                continue
            }
            feeding = true
            try {
                if (next is Key) feed(next).also { fed++ } else (next as Action).run()
            } finally {
                feeding = false
            }
        }
        if (fed > 0 && forRime) fedForRime(fed)
        if (!hasKeys()) forRime = false
    }

    private fun start(run: (finish: (edit: () -> Unit) -> Unit) -> Unit) {
        switching = true
        val started = generation
        run { edit ->
            if (started == generation) {
                switching = false
                feeding = true
                try {
                    edit()
                } finally {
                    feeding = false
                }
                drain()
            }
        }
    }

    /** What the keys would leave as 中文's reading: letters add to it, Delete takes one off, anything else ends it. */
    fun reading() = queue.fold(StringBuilder()) { reading, entry ->
        when ((entry as? Key)?.code) {
            Code.TEXT -> reading.append((entry as Key).text)
            Code.DELETE -> if (reading.isNotEmpty()) reading.setLength(reading.length - 1)
            else -> reading.setLength(0)
        }
        reading
    }.toString()
}
