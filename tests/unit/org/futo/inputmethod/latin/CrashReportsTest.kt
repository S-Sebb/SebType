package org.futo.inputmethod.latin

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A crash report carries no typed text, settings or login (#33, H7 in #26). Made-up text and login. */
class CrashReportsTest {
    private val typed = "my made-up typed words 你好"
    private val password = "made-up-pass-4821"

    @Test
    fun reportKeepsTheCodeAndDropsEveryMessage() {
        val error = IllegalStateException("Expected composingText [$typed]",
            RuntimeException("login $password failed"))
        val log = listOf(
            "11-11 20:23:04.101  1234  1250 E InputConnectionInternalComposingWrapper: Expected composingText [$typed], but actually got []",
            "11-11 20:23:04.102  1234  1250 W ExpandableBinaryDictionary: Cannot update counter. word: $typed",
            "11-11 20:23:04.103  1234  1250 E AndroidRuntime: java.lang.IllegalStateException: $typed",
            "11-11 20:23:04.104  1234  1250 E AndroidRuntime: \tat org.futo.inputmethod.latin.LatinIME.onKey(LatinIME.kt:42)",
            "11-11 20:23:04.105  1234  1250 E AndroidRuntime: Caused by: java.lang.RuntimeException: login $password failed",
            "11-11 20:23:04.106  1234  1250 W Prefs: {sync_account=$password, theme=Picnic} at home(now)",
            "11-11 20:23:04.107  1234  1250 W SebType sync: Sync failed (SocketTimeoutException)",
            "--------- beginning of crash",
            "$typed on a line of its own",
        )
        val report = CrashReports.report(listOf("SebType 1.0", "Device: Made-up Phone"), "main", error, log)

        listOf(typed, "你好", password, "theme", "Picnic", "home(now)", "beginning of crash").forEach {
            assertFalse("'$it' in the report:\n$report", report.contains(it))
        }
        listOf(
            "Device: Made-up Phone",
            "java.lang.IllegalStateException\n",
            "Caused by: java.lang.RuntimeException\n",
            "\tat org.futo.inputmethod.latin.CrashReportsTest.reportKeepsTheCodeAndDropsEveryMessage(CrashReportsTest.kt:",
            "E AndroidRuntime: java.lang.IllegalStateException: [message removed]",
            "E AndroidRuntime: \tat org.futo.inputmethod.latin.LatinIME.onKey(LatinIME.kt:42)",
            "E AndroidRuntime: Caused by: java.lang.RuntimeException: [message removed]",
            "W ExpandableBinaryDictionary: [message removed]",
            "W SebType sync: Sync failed (SocketTimeoutException)",
        ).forEach { assertTrue("'$it' missing from the report:\n$report", report.contains(it)) }
    }

    @Test
    fun aCauseLoopEnds() {
        val a = RuntimeException("a")
        val b = IllegalArgumentException("b", a)
        a.initCause(b)
        assertEquals(2, CrashReports.stackTrace(a).lines().count { !it.startsWith("\tat") && it.isNotEmpty() })
    }
}
