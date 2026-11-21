package dev.sebb.sebtype

import dev.sebb.sebtype.core.NativeState
import org.junit.Assert.assertEquals
import org.junit.Test

class EngineTextTest {
    private fun st(preedit: String, commit: String = "", deleteBefore: Int = 0, recompose: Boolean = false, composeBefore: Int = 0) =
        NativeState(true, commit, deleteBefore, 0, 0, recompose, composeBefore, 0, arrayOf(preedit), BooleanArray(1), -1,
            emptyArray(), emptyArray(), -1)

    @Test fun pickedSuggestionIsBeforeTheNextWord() {
        // "Hel" typed at the start of a sentence, then the suggestion "Hello" tapped: the next letter follows
        // "Hello ", not the start of the sentence it would be a capital at (#453)
        val text = EngineText()
        text.enter("")
        listOf("H", "He", "Hel").forEach { text.record(st(it)) }
        text.record(st("", commit = "Hello "))
        assertEquals("Hello ", text.toString())
    }

    @Test fun reopenedWordIsTypedOnce() {
        // Delete at "Hi there |" reopens "there" over it and the space (core/'s reopenBeforeDeleted): it is what
        // is typed, not text before it too
        val text = EngineText()
        text.enter("Hi there ")
        text.record(st("there", recompose = true, composeBefore = 6))
        assertEquals("Hi there", text.toString())
    }

    @Test fun keyTheEngineDidNotTake() {
        val text = EngineText()
        text.enter("Hi")
        text.typed(".")
        text.typed(null)
        text.typed(null)
        assertEquals("H", text.toString())
    }
}
