package org.futo.inputmethod.latin

import android.content.Context
import android.os.Build
import android.os.Process
import android.util.Log
import org.futo.inputmethod.engine.general.SyncAccountStore
import org.futo.inputmethod.engine.general.SyncServer
import org.futo.inputmethod.latin.uix.isDirectBootUnlocked
import java.io.File
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.random.Random

/**
 * Crash reports to the user's own sync server (#33; Decisions #2: "Send to sync server.", "Also recent
 * SebType logs"). A crash while sync is on leaves a report in no-backup storage, and the next sync
 * uploads it (`PUT /v1/crashes/<name>` of sync-server/sebtype_sync.py) and deletes it here. A crash while
 * sync is off leaves nothing.
 *
 * A report holds the stack trace, the versions, the device model and SebType's last warnings and errors,
 * and never typed text, settings or the login: nothing reads settings or the login into it, and no
 * exception or log message goes in, as any of them may quote text. Only the code's own structure does
 * (exception classes, stack frames, log tags), plus the messages of [SAFE_TAGS].
 */
object CrashReports {
    private const val TAG = "SebType crash"
    private const val MAX_QUEUED = 10
    private const val LOG_LINES = 200
    private val NAME = Regex("""crash-\d{8}-\d{6}-[0-9a-f]{6}\.txt""")

    /** Tags whose messages are SebType's own and never carry text; read a tag's log lines before adding it. */
    private val SAFE_TAGS = setOf(TAG, "SebType sync")

    // logcat -v threadtime: "11-11 20:23:04.123  1234  1250 W Tag: message"
    private val LOG_LINE = Regex("""^(\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})\s+\d+\s+\d+ ([VDIWEFA]) (.*?)\s*:\s?(.*)$""")
    // The lines Log.w/e(tag, message, exception) adds: frames and exception classes are code.
    private val FRAME = Regex("""\s*(at ([\w$<>-]+\.)+[\w$<>-]+\(([\w$-]+\.(java|kt):\d+|Native Method|Unknown Source)\)|\.\.\. \d+ more)""")
    private val EXCEPTION = Regex("""\s*(Caused by: |Suppressed: )?([a-z]\w*\.)+[A-Z][\w$]*(Exception|Error|Throwable)\b""")

    private fun queue(context: Context) = File(context.noBackupFilesDir, "crash-reports")

    private fun queued(context: Context) =
        queue(context).listFiles { f -> NAME.matches(f.name) }.orEmpty().sortedBy { it.name }

    /** Records uncaught exceptions of every thread in the process, before Android ends it. */
    fun install(context: Context) {
        val app = context.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            // Nothing may stop the crash from reaching Android's own handler.
            try { save(app, thread, error) } catch(e: Throwable) {}
            previous?.uncaughtException(thread, error)
        }
    }

    private fun save(context: Context, thread: Thread, error: Throwable) {
        if(!context.isDirectBootUnlocked) return
        val account = SyncAccountStore.current.value ?: SyncAccountStore.load(context)
        if(account?.enabled != true) return
        val now = Date()
        val about = listOf(
            "SebType ${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}, ${BuildConfig.FLAVOR} ${BuildConfig.BUILD_TYPE})",
            "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT}), ${Build.SUPPORTED_ABIS.firstOrNull()}",
            "Device: ${Build.MANUFACTURER} ${Build.MODEL}",
            "Time: ${utc("yyyy-MM-dd HH:mm:ss 'UTC'", now)}",
        )
        val dir = queue(context).apply { mkdirs() }
        val name = "crash-${utc("yyyyMMdd-HHmmss", now)}-${"%06x".format(Random.nextInt(1 shl 24))}.txt"
        val tmp = File(dir, "$name.tmp")
        tmp.writeText(report(about, thread.name, error, recentLog()))
        tmp.renameTo(File(dir, name))
        queued(context).dropLast(MAX_QUEUED).forEach { it.delete() }
    }

    private fun utc(pattern: String, time: Date) =
        SimpleDateFormat(pattern, Locale.ROOT).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(time)

    /** SebType's last warnings and errors: an app reads only its own process's log. */
    private fun recentLog(): List<String> = try {
        val logcat = ProcessBuilder("logcat", "-d", "-v", "threadtime", "-t", "$LOG_LINES",
            "--pid=${Process.myPid()}", "*:W").redirectErrorStream(true).start()
        logcat.inputStream.bufferedReader().readLines().also { logcat.waitFor() }
    } catch(e: IOException) {
        emptyList()
    }

    internal fun report(about: List<String>, thread: String, error: Throwable, log: List<String>) = buildString {
        about.forEach { appendLine(it) }
        appendLine("Thread: $thread")
        appendLine()
        append(stackTrace(error))
        appendLine()
        appendLine("Last warnings and errors (messages removed, except stack frames and SebType's own):")
        log.mapNotNull(::logLine).forEach { appendLine(it) }
    }

    /** The exception, its causes and their frames, without their messages. */
    internal fun stackTrace(error: Throwable) = buildString {
        val seen = mutableSetOf<Throwable>()
        var e: Throwable? = error
        while(e != null && seen.add(e)) {
            appendLine((if(e === error) "" else "Caused by: ") + e.javaClass.name)
            e.stackTrace.forEach { appendLine("\tat $it") }
            e = e.cause
        }
    }

    /** A logcat line as "time level tag: message", the message removed unless it is safe; null for other lines. */
    internal fun logLine(line: String): String? {
        val (time, level, tag, message) = LOG_LINE.find(line)?.destructured ?: return null
        val kept = if(tag in SAFE_TAGS || FRAME.matches(message)) message else {
            val exception = EXCEPTION.find(message)?.takeIf { it.range.first == 0 }?.value
            if(exception == message) message else listOfNotNull(exception, "[message removed]").joinToString(": ")
        }
        return "$time $level $tag: $kept"
    }

    /**
     * Uploads the queued reports, oldest first, deleting each one sent; every sync calls it. A failure leaves
     * them for the next sync and doesn't fail the sync of learned words (a server without crash reports, #33).
     */
    fun upload(context: Context, server: SyncServer) {
        for(file in queued(context)) {
            try {
                server.uploadCrashReport(file.name, file.readBytes())
            } catch(e: IOException) {
                Log.w(TAG, "Uploading a crash report failed (${e.javaClass.simpleName})")
                return
            }
            file.delete()
        }
    }
}
