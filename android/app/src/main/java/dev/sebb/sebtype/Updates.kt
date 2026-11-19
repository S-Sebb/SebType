package dev.sebb.sebtype

import android.app.Activity
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationChannelCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.IntentCompat
import dev.sebb.sebtype.data.Prefs
import dev.sebb.sebtype.settings.SettingsActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.TimeUnit

/**
 * SebType's own update check and install (#422): the latest GitHub release of S-Sebb/SebType, once a day
 * ([UpdateJob]) while Settings › About's switch is on, and from that screen's "Check for updates". The
 * request carries nothing but itself: no login, no device ID, and SebType's own User-Agent instead of
 * Android's, which names the phone's model. A newer release shows in the settings and as a notification;
 * tapping either downloads its APK into the cache and hands it to Android's installer, which only takes an
 * APK signed with SebType's key.
 */
object Updates {
    /** A release newer than this app: its version (x.y.z) and its arm64 APK's URL */
    data class Release(val version: String, val apk: String)

    sealed interface Status {
        data object Idle : Status
        data object Checking : Status
        data object UpToDate : Status
        data object CheckFailed : Status
        data class Downloading(val percent: Int) : Status
        /** Sent to Android's "Install unknown apps" for SebType; coming back goes on ([resumed]) */
        data object NeedsPermission : Status
        data object Installing : Status
        /** [text]: a string resource, formatted with [detail] */
        data class Failed(val text: Int, val detail: String = "") : Status
    }

    /** What the settings show while a check or an install runs */
    val status = MutableStateFlow<Status>(Status.Idle)
    /** The newer release found last, kept across restarts until it is installed */
    val available = MutableStateFlow<Release?>(null)

    /** The settings' intent extra that installs [available], from the notification */
    const val EXTRA_INSTALL = "dev.sebb.sebtype.INSTALL_UPDATE"
    private const val JOB = 422
    private const val CHANNEL = "updates"
    private const val TAG = "SebType updates"
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private fun store(context: Context) = context.getSharedPreferences("updates", Context.MODE_PRIVATE)

    /** True the first time the settings show the daily check's switch */
    fun firstMet(context: Context): Boolean {
        val p = store(context)
        if (p.getBoolean("met", false)) return false
        p.edit().putBoolean("met", true).apply()
        return true
    }

    /** Whether this build checks: a release build always, a debug build only for a test release ([updateSource]) */
    fun enabled(context: Context) = updateSource(context) != null

    /** From [App]: the release found last, and the daily check scheduled while its switch is on. */
    fun start(context: Context) {
        val app = context.applicationContext
        scope.launch {
            if (!enabled(app)) return@launch
            available.value = saved(app)
            Prefs.flow(app, Prefs.UPDATE_CHECK).distinctUntilChanged().collect { schedule(app, it) }
        }
    }

    private fun schedule(context: Context, on: Boolean) {
        val jobs = context.getSystemService(JobScheduler::class.java)
        if (!on) return jobs.cancel(JOB)
        // Not persisted, which would need RECEIVE_BOOT_COMPLETED: the keyboard starts this process after a reboot.
        if (jobs.getPendingJob(JOB) != null) return
        jobs.schedule(JobInfo.Builder(JOB, ComponentName(context, UpdateJob::class.java))
            .setPeriodic(TimeUnit.DAYS.toMillis(1))
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
            .build())
    }

    // Plain semver without a pre-release or build part: never the v0.1.30-sebtype.N of the releases before 0.1.0.
    private val PLAIN = Regex("""(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})""")
    private val LEADING = Regex("""^(\d{1,9})\.(\d{1,9})\.(\d{1,9})""")

    private fun parts(m: MatchResult) = m.groupValues.drop(1).map(String::toInt)

    /**
     * Whether [version] (plain x.y.z) is newer than the installed [versionName]. The installed one counts by
     * its leading x.y.z, so a 0.1.30-sebtype.N build reads as 0.1.30; one without ("dev") is offered nothing.
     */
    fun newer(version: String, versionName: String): Boolean {
        val offered = PLAIN.matchEntire(version)?.let(::parts) ?: return false
        val installed = LEADING.find(versionName)?.let(::parts) ?: return false
        return offered.zip(installed).map { (a, b) -> a.compareTo(b) }.firstOrNull { it != 0 } ?: 0 > 0
    }

    /** GitHub's latest release ([json]), if its tag v<x.y.z> is newer than [versionName] and it has its arm64 APK */
    fun release(json: String, versionName: String): Release? {
        val o = JSONObject(json)
        val version = o.optString("tag_name").takeIf { it.startsWith("v") }?.substring(1) ?: return null
        if (!newer(version, versionName)) return null
        val assets = o.optJSONArray("assets") ?: return null
        val name = "SebType-$version-arm64-v8a.apk"
        return (0 until assets.length()).map(assets::getJSONObject).firstOrNull { it.optString("name") == name }
            ?.let { Release(version, it.getString("browser_download_url")) }
    }

    private fun saved(context: Context): Release? {
        val p = store(context)
        val release = Release(p.getString("version", null) ?: return null, p.getString("apk", null) ?: return null)
        if (newer(release.version, BuildConfig.VERSION_NAME)) return release
        p.edit().remove("version").remove("apk").apply() // installed since
        return null
    }

    fun checkNow(context: Context) {
        val app = context.applicationContext
        scope.launch { check(app, notify = false) }
    }

    /**
     * Asks GitHub for the latest release. [notify]: the daily check, which leaves [status] to the settings and
     * notifies of each release once. False if GitHub couldn't be reached.
     */
    suspend fun check(context: Context, notify: Boolean): Boolean = withContext(Dispatchers.IO) {
        val url = updateSource(context) ?: return@withContext true
        if (!notify) status.value = Status.Checking
        val release = try {
            release(get(url), BuildConfig.VERSION_NAME)
        } catch (e: Exception) { // the network, or a page that isn't GitHub's JSON
            Log.w(TAG, "Update check failed (${e.javaClass.simpleName})")
            if (!notify) status.value = Status.CheckFailed
            return@withContext false
        }
        val p = store(context)
        p.edit().apply {
            if (release == null) remove("version").remove("apk")
            else putString("version", release.version).putString("apk", release.apk)
        }.apply()
        available.value = release
        if (!notify) status.value = if (release == null) Status.UpToDate else Status.Idle
        if (notify && release != null && p.getString("notified", null) != release.version && notifyOf(context, release)) {
            p.edit().putString("notified", release.version).apply()
        }
        true
    }

    private fun open(url: String) = (URL(url).openConnection() as HttpURLConnection).apply {
        connectTimeout = 15_000
        readTimeout = 30_000
        useCaches = false
        setRequestProperty("User-Agent", "SebType")
    }

    private fun get(url: String): String {
        val c = open(url)
        try {
            c.setRequestProperty("Accept", "application/vnd.github+json")
            if (c.responseCode != 200) throw IOException("HTTP ${c.responseCode}")
            return c.inputStream.bufferedReader().readText()
        } finally {
            c.disconnect()
        }
    }

    /** Opens the settings on About and installs [available] */
    fun installIntent(context: Context): Intent = Intent(context, SettingsActivity::class.java)
        .putExtra(EXTRA_INSTALL, true)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)

    /** False where SebType may not notify (Android 13+ asks first, Settings › About) */
    private fun notifyOf(context: Context, release: Release): Boolean {
        val nm = NotificationManagerCompat.from(context)
        if (!nm.areNotificationsEnabled()) return false
        nm.createNotificationChannel(NotificationChannelCompat.Builder(CHANNEL, NotificationManagerCompat.IMPORTANCE_DEFAULT)
            .setName(context.getString(R.string.update_channel)).build())
        val open = PendingIntent.getActivity(context, 0, installIntent(context),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_launcher_foreground)
            .setContentTitle(context.getString(R.string.update_available, release.version))
            .setContentText(context.getString(R.string.update_tap))
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        return try {
            nm.notify(JOB, notification)
            true
        } catch (e: SecurityException) {
            false
        }
    }

    /** Downloads [available] and hands it to Android's installer, first sending the user to allow that if needed. */
    fun install(activity: Activity) {
        val release = available.value ?: return
        val now = status.value
        if (now is Status.Downloading || now == Status.Installing) return
        if (Build.VERSION.SDK_INT >= 26 && !activity.packageManager.canRequestPackageInstalls()) {
            status.value = Status.NeedsPermission
            activity.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")))
            return
        }
        val app = activity.applicationContext
        status.value = Status.Downloading(0)
        scope.launch { download(app, release) }
    }

    /** From the settings' onResume: back from allowing installs, the install goes on. */
    fun resumed(activity: Activity) {
        if (status.value == Status.NeedsPermission && Build.VERSION.SDK_INT >= 26 &&
            activity.packageManager.canRequestPackageInstalls()) install(activity)
    }

    private fun download(context: Context, release: Release) {
        val apk = File(context.cacheDir, "update/SebType.apk")
        try {
            apk.parentFile!!.mkdirs()
            val c = open(release.apk) // GitHub redirects to its file host, over HTTPS too
            try {
                if (c.responseCode != 200) throw IOException("HTTP ${c.responseCode}")
                val size = c.contentLengthLong
                c.inputStream.use { input ->
                    apk.outputStream().use { out ->
                        val buffer = ByteArray(64 * 1024)
                        var done = 0L
                        while (true) {
                            val n = input.read(buffer)
                            if (n < 0) break
                            out.write(buffer, 0, n)
                            done += n
                            if (size > 0) status.value = Status.Downloading((done * 100 / size).toInt())
                        }
                    }
                }
            } finally {
                c.disconnect()
            }
            // An APK of this app; Android checks that SebType's key signed it.
            if (context.packageManager.getPackageArchiveInfo(apk.path, 0)?.packageName != context.packageName) {
                status.value = Status.Failed(R.string.update_not_sebtype)
                return
            }
            status.value = Status.Installing
            hand(context, apk)
        } catch (e: IOException) {
            Log.w(TAG, "Update download failed (${e.javaClass.simpleName})")
            status.value = Status.Failed(R.string.update_download_failed)
        } finally {
            apk.delete()
        }
    }

    private fun hand(context: Context, apk: File) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
            .apply { setAppPackageName(context.packageName) }
        val id = installer.createSession(params)
        installer.openSession(id).use { session ->
            session.openWrite("SebType.apk", 0, apk.length()).use { out ->
                apk.inputStream().use { it.copyTo(out) }
                session.fsync(out)
            }
            // Mutable: the installer adds its status and, for the user's confirmation, its own screen
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
            session.commit(PendingIntent.getBroadcast(context, id, Intent(context, UpdateInstalled::class.java), flags).intentSender)
        }
    }
}

/** The daily check, scheduled by [Updates.start] */
class UpdateJob : JobService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onStartJob(params: JobParameters): Boolean {
        scope.launch { jobFinished(params, !Updates.check(this@UpdateJob, notify = true)) }
        return true
    }

    override fun onStopJob(params: JobParameters) = true
}

/** Android's installer answering [Updates]' install */
class UpdateInstalled : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            // Its "Do you want to update this app?" screen
            PackageInstaller.STATUS_PENDING_USER_ACTION ->
                IntentCompat.getParcelableExtra(intent, Intent.EXTRA_INTENT, Intent::class.java)
                    ?.let { context.startActivity(it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
            PackageInstaller.STATUS_SUCCESS, PackageInstaller.STATUS_FAILURE_ABORTED -> Updates.status.value = Updates.Status.Idle
            else -> Updates.status.value = Updates.Status.Failed(R.string.update_install_failed,
                intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE).orEmpty())
        }
    }
}
