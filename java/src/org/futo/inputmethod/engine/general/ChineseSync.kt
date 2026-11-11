package org.futo.inputmethod.engine.general

import android.content.Context
import android.os.SystemClock
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.futo.inputmethod.latin.CrashReports
import org.futo.inputmethod.latin.uix.isDirectBootUnlocked
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.KeyStore
import java.security.MessageDigest
import java.util.concurrent.atomic.AtomicLong
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.net.ssl.HttpsURLConnection

/** The user's own sync server and login (#12, Decisions #2: bring your own server, its own login). */
data class SyncAccount(val server: String, val user: String, val password: String, val enabled: Boolean) {
    companion object {
        /** "host", "host:port/path" or "https://…" as an https URL without a trailing slash; null for anything else. */
        fun normalizeServer(text: String): String? {
            val t = text.trim().trimEnd('/')
            val url = if("://" in t) t else "https://$t"
            return url.takeIf {
                it.startsWith("https://") && runCatching { URL(it).host.isNotEmpty() }.getOrDefault(false)
            }
        }
    }
}

/**
 * The account, encrypted with a key that never leaves the Android Keystore, in no-backup storage: out of
 * backups, device transfer and settings exports (H10, #26), as nothing else touches that file.
 */
object SyncAccountStore {
    private const val KEY_ALIAS = "sebtype_sync_account"
    /** The account as last loaded or saved, for the settings screen. */
    val current = MutableStateFlow<SyncAccount?>(null)
    private fun file(context: Context) = File(context.noBackupFilesDir, "sync/account")

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build())
        }.generateKey()
    }

    @Synchronized
    fun load(context: Context): SyncAccount? = read(context).also { current.value = it }

    private fun read(context: Context): SyncAccount? {
        val bytes = file(context).takeIf { it.isFile }?.readBytes() ?: return null
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 0, 12))
            val json = JSONObject(String(cipher.doFinal(bytes, 12, bytes.size - 12)))
            SyncAccount(json.getString("server"), json.getString("user"), json.getString("password"),
                json.getBoolean("enabled"))
        } catch(e: Exception) {
            // The key is gone (app data cleared on some phones, a restored file): the login is entered again.
            Log.w(TAG, "Can't read the sync account (${e.javaClass.simpleName})")
            null
        }
    }

    @Synchronized
    fun save(context: Context, account: SyncAccount?) {
        val file = file(context)
        current.value = account
        if(account == null) { file.delete(); return }
        val json = JSONObject().put("server", account.server).put("user", account.user)
            .put("password", account.password).put("enabled", account.enabled)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val sealed = cipher.iv + cipher.doFinal(json.toString().toByteArray())
        file.parentFile!!.mkdirs()
        val tmp = File(file.path + ".tmp")
        tmp.writeBytes(sealed)
        if(!tmp.renameTo(file)) throw IOException("Can't save the sync account")
    }

    private const val TAG = "SebType sync"
}

class SyncLoginFailed : IOException("login failed")

/**
 * SebType's only network client, used only for the user's sync server (H10, #26) and its crash reports
 * (#33): HTTPS only (the app's
 * network security config forbids cleartext too), Basic auth, the API of `sync-server/sebtype_sync.py`.
 */
class SyncServer(private val account: SyncAccount) {
    data class RemoteFile(val device: String, val name: String, val sha256: String)

    private val auth = "Basic " + Base64.encodeToString(
        "${account.user}:${account.password}".toByteArray(), Base64.NO_WRAP)

    private fun <T> request(method: String, path: String, body: ByteArray? = null, read: (HttpURLConnection) -> T): T {
        val url = URL(account.server + path)
        if(url.protocol != "https") throw IOException("not https")
        val c = url.openConnection() as HttpsURLConnection
        try {
            c.requestMethod = method
            c.connectTimeout = 15_000
            c.readTimeout = 30_000
            c.useCaches = false
            c.instanceFollowRedirects = false // the login goes to the configured server only
            c.setRequestProperty("Authorization", auth)
            if(body != null) {
                c.doOutput = true
                c.setFixedLengthStreamingMode(body.size)
                c.outputStream.use { it.write(body) }
            }
            when(c.responseCode) {
                in 200..299 -> return read(c)
                401, 403 -> throw SyncLoginFailed()
                else -> throw IOException("HTTP ${c.responseCode}")
            }
        } finally {
            c.disconnect()
        }
    }

    fun list(): List<RemoteFile> = request("GET", "/v1/files") { c ->
        val files = JSONObject(c.inputStream.bufferedReader().readText()).getJSONArray("files")
        (0 until files.length()).map { files.getJSONObject(it) }.map {
            RemoteFile(it.getString("device"), it.getString("name"), it.getString("sha256"))
        }
    }

    fun download(file: RemoteFile): ByteArray =
        request("GET", "/v1/files/${file.device}/${file.name}") { c -> c.inputStream.use { it.readBytes() } }

    fun upload(device: String, name: String, bytes: ByteArray) = request("PUT", "/v1/files/$device/$name", bytes) {}

    fun uploadCrashReport(name: String, bytes: ByteArray) = request("PUT", "/v1/crashes/$name", bytes) {}

    fun deleteAll() = request("DELETE", "/v1/files") {}
}

/**
 * Syncs 中文's learned words with the user's server (#12) through Rime's sync folder,
 * `<user dir>/sync/<installation id>/`: each device writes only its own folder and merges in the
 * others' (study report on #3, section 6). A sync downloads the other devices' changed snapshots,
 * lets Rime merge them and write this phone's, and uploads that; Rime runs only when something
 * changed. The same folders carry the Japanese and English personal dictionaries
 * ([PersonalDictionarySync], #14). It runs in the background while the keyboard is hidden: when it
 * hides (at most once a minute) and every half hour. Offline, Rime keeps learning as always and the
 * next sync takes everything along.
 */
object ChineseSync {
    private const val TAG = "SebType sync"
    private const val TIMER_MS = 30 * 60_000L
    // Hiding the keyboard syncs at most this often: one small request when nothing changed.
    private const val RETRY_MS = 60_000L
    private val FILE = Regex("[A-Za-z0-9][A-Za-z0-9._-]{0,99}\\.userdb\\.txt")
    private val DEVICE = Regex("[A-Za-z0-9][A-Za-z0-9._-]{0,63}")

    sealed interface Status {
        data object Off : Status
        data object NotYet : Status
        data object Syncing : Status
        data class Synced(val atMillis: Long) : Status
        data object Offline : Status
        data object LoginFailed : Status
    }

    private val mutableStatus = MutableStateFlow<Status>(Status.Off)
    val status: StateFlow<Status> = mutableStatus

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutex = Mutex()
    @Volatile private var keyboardShown = false
    private val lastTry = AtomicLong(0L)
    private var timerStarted = false

    private fun stateFile(context: Context) = File(context.noBackupFilesDir, "sync/last-merge")

    /** Starts the half-hourly sync, once per process. */
    @Synchronized
    fun start(context: Context) {
        if(timerStarted) return
        timerStarted = true
        val app = context.applicationContext
        scope.launch { refresh(app) }
        scope.launch {
            while(true) {
                delay(TIMER_MS)
                if(!keyboardShown) sync(app)
            }
        }
    }

    fun onKeyboardShown() { keyboardShown = true }

    fun onKeyboardHidden(context: Context) {
        keyboardShown = false
        val app = context.applicationContext
        val now = SystemClock.elapsedRealtime()
        val last = lastTry.get()
        if(now - last < RETRY_MS || !lastTry.compareAndSet(last, now)) return
        scope.launch { sync(app) }
    }

    /** The status from the saved account and the last merge, for a new process (the settings screen). */
    suspend fun refresh(context: Context) = withContext(Dispatchers.IO) {
        if(!context.isDirectBootUnlocked) return@withContext
        val account = SyncAccountStore.load(context)
        if(account?.enabled != true) mutableStatus.value = Status.Off
        else if(mutableStatus.value == Status.Off) mutableStatus.value =
            stateFile(context).takeIf { it.isFile }?.lastModified()?.let { Status.Synced(it) } ?: Status.NotYet
    }

    private fun user(context: Context) = ChineseIME.getUser(context)

    // Set while Rime has something to merge: a commit it may have learned from, or a download. A file,
    // so a commit before the process ends is still synced.
    private fun mergeFile(context: Context) = File(context.noBackupFilesDir, "sync/merge-needed")
    @Volatile private var mergeMarked = false

    private fun markMerge(context: Context) {
        mergeMarked = true
        mergeFile(context).apply { parentFile!!.mkdirs(); createNewFile() }
    }

    /** 中文 committed text where Rime learns: the next sync merges. */
    fun onChineseCommit(context: Context) {
        if(mergeMarked) return
        val app = context.applicationContext
        mergeMarked = true
        scope.launch { markMerge(app) }
    }

    private fun installationId(context: Context): String? =
        File(user(context), "installation.yaml").takeIf { it.isFile }?.readLines()
            ?.firstNotNullOfOrNull { Regex("""installation_id:\s*"?([^"\s]+)"?""").find(it)?.groupValues?.get(1) }
            ?.takeIf { DEVICE.matches(it) }

    private fun sha256(bytes: ByteArray) =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    suspend fun sync(context: Context): Unit = withContext(Dispatchers.IO) {
        if(!context.isDirectBootUnlocked) return@withContext
        mutex.withLock {
            val account = SyncAccountStore.load(context)
            if(account?.enabled != true) { mutableStatus.value = Status.Off; return@withLock }
            val previous = mutableStatus.value
            mutableStatus.value = Status.Syncing
            mutableStatus.value = try {
                val server = SyncServer(account)
                syncWith(context, server).also { CrashReports.upload(context, server) }
            } catch(e: SyncLoginFailed) {
                Status.LoginFailed
            } catch(e: IOException) {
                // No address, port or words in the log (H10): only what kind of failure it was.
                Log.w(TAG, "Sync failed (${e.javaClass.simpleName})")
                Status.Offline
            } ?: previous
        }
    }

    /** One sync; null if Rime was busy (the keyboard came up), so it is left for the next one. */
    private suspend fun syncWith(context: Context, server: SyncServer): Status? {
        val sync = File(user(context), "sync")
        var remote = server.list()
        val ownBefore = installationId(context)
        for(file in remote) {
            val dictionary = file.name in PersonalDictionarySync.FILES
            if(file.device == ownBefore || !DEVICE.matches(file.device) || !(dictionary || FILE.matches(file.name))) continue
            val local = File(sync, "${file.device}/${file.name}")
            val old = local.takeIf { it.isFile }?.readBytes()
            if(old != null && sha256(old) == file.sha256) continue
            val bytes = server.download(file)
            // The copy kept here is what the next download is compared with, so it is saved after the words.
            if(dictionary) PersonalDictionarySync.takeIn(context, file.name, bytes, old)
            local.parentFile!!.mkdirs()
            val tmp = File(local.path + ".tmp")
            tmp.writeBytes(bytes)
            if(!tmp.renameTo(local)) throw IOException("can't save a download")
            if(!dictionary) markMerge(context)
        }

        if(mergeFile(context).exists() || remote.none { it.device == ownBefore }) {
            if(keyboardShown) return null
            // Cleared first: a commit during the merge marks it again.
            mergeMarked = false
            mergeFile(context).delete()
            if(!RimeIceSetup.syncUserData(context)) { markMerge(context); return null }
            stateFile(context).apply { parentFile!!.mkdirs(); writeText("") }
        }

        // The id exists once Rime has run its first sync.
        val own = installationId(context) ?: return Status.Synced(System.currentTimeMillis())
        if(own != ownBefore) remote = server.list()
        val uploaded = remote.filter { it.device == own }.associate { it.name to it.sha256 }
        val files = File(sync, own).listFiles { f -> FILE.matches(f.name) }.orEmpty().associate { it.name to it.readBytes() }
        (files + PersonalDictionarySync.snapshots(context)).forEach { (name, bytes) ->
            if(uploaded[name] != sha256(bytes)) server.upload(own, name, bytes)
        }
        return Status.Synced(System.currentTimeMillis())
    }

    /** Saves the account with sync on or off, in the background, and syncs at once when on. */
    fun setEnabled(context: Context, account: SyncAccount, enabled: Boolean) {
        val app = context.applicationContext
        scope.launch {
            SyncAccountStore.save(app, account.copy(enabled = enabled))
            mutableStatus.value = if(enabled) Status.NotYet else Status.Off
            if(enabled) sync(app)
        }
    }

    /**
     * Deletes the learned words stored on the server (Decisions #2, #73) and turns sync off, so this
     * phone doesn't upload its own again until sync is turned back on. The phone's learned words stay.
     * [onDone] runs on the main thread with whether it worked.
     */
    fun deleteOnServer(context: Context, onDone: (Boolean) -> Unit) {
        val app = context.applicationContext
        scope.launch {
            val deleted = mutex.withLock {
                val account = SyncAccountStore.load(app) ?: return@withLock false
                try {
                    SyncServer(account).deleteAll()
                } catch(e: IOException) {
                    Log.w(TAG, "Deleting on the server failed (${e.javaClass.simpleName})")
                    return@withLock false
                }
                SyncAccountStore.save(app, account.copy(enabled = false))
                mutableStatus.value = Status.Off
                true
            }
            withContext(Dispatchers.Main) { onDone(deleted) }
        }
    }
}
