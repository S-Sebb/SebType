package dev.sebb.sebtype

import dev.sebb.sebtype.Layout.Code
import dev.sebb.sebtype.core.NativeCore.CHINESE
import dev.sebb.sebtype.core.NativeCore.ENGLISH
import dev.sebb.sebtype.core.NativeCore.JAPANESE

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
    /** A key, with what the keyboard knew when it was tapped: [userShift], the user's Shift (KeyboardView.typedWithUserShift). */
    class Key(val code: Code, val text: String, val x: Int, val y: Int, val userShift: Boolean?)

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

/**
 * A key's text outside English: only English turns Shift on by itself, so a capital A–Z there without the
 * user's Shift is English's, from a key tapped before the globe that waited its turn (#351).
 */
fun withoutEnglishShift(text: String, userShift: Boolean?) =
    if (userShift != true && text.length == 1 && text[0] in 'A'..'Z') text.lowercase() else text

/**
 * An English letter as typed: in the case the user's Shift set ([userShift] true or false), else (null) a
 * capital where the field asks for one ([fieldCapital]). Shift turned off cancels the field's capital (#479).
 */
fun englishLetter(text: String, userShift: Boolean?, fieldCapital: () -> Boolean) = when (userShift) {
    true -> text
    false -> text.lowercase()
    null -> if (fieldCapital()) text.uppercase() else text.lowercase()
}

/** What an edit that ends typing (the keyboard's finishTyping) asks of the engine first */
enum class EndTyping { NOTHING, FLUSH, CLEAR, UNDO }

/**
 * [EndTyping] for [lang], with the engine [composing] or not. 日本語's Undo is Mozc's own, as today's app's (#379):
 * a conversion just committed comes back as its reading, and one being typed goes back a step, so nothing is
 * flushed before it. Otherwise what is typed goes in (中文's pinyin is dropped) and the app does the edit.
 */
fun endTyping(lang: Int, composing: Boolean, undo: Boolean) = when {
    undo && lang == JAPANESE -> EndTyping.UNDO
    !composing -> EndTyping.NOTHING
    lang == CHINESE -> EndTyping.CLEAR
    else -> EndTyping.FLUSH
}

/**
 * The language 🌐's tap goes to from [lang], of those on in globe [order]. [quick] (#526, as Win+Space on the PCs):
 * English ⇄ the [last] other language used, the first other one on until one was used. Off, or with English off:
 * the next one in the order.
 */
fun globeTarget(order: List<Int>, lang: Int, quick: Boolean, last: Int): Int {
    if (!quick || ENGLISH !in order) return order[(order.indexOf(lang) + 1) % order.size]
    if (lang != ENGLISH) return ENGLISH
    return last.takeIf { it in order && it != ENGLISH } ?: order.firstOrNull { it != ENGLISH } ?: ENGLISH
}
