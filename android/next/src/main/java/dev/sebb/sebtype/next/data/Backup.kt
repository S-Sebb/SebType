package dev.sebb.sebtype.next.data

import android.content.Context
import android.util.Log
import androidx.datastore.preferences.core.PreferencesSerializer
import dev.sebb.sebtype.core.NativeCore
import dev.sebb.sebtype.next.Engines
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okio.buffer
import okio.source
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.CountDownLatch
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

/**
 * Settings export and import (#34): one zip of the options, the learned words of all three languages, the
 * personal dictionaries and, when ticked, the clipboard history. Its entries are the ones today's app writes,
 * so a backup from either app imports into the other's data.
 */
object Backup {
    private const val TAG = "SebType"
    private const val PREFS = "datastore.preferences_pb"
    private const val CONF = "sebtype.conf"
    private const val WORDS = "userdictionary.json"
    private const val CLIPBOARD = "clipboard.json"
    private const val CLIPBOARD_FILES = "clipboard/"
    // Rime's id for this phone: it names the phone's folder on the sync server, so no two phones may share it (#169).
    private const val INSTALLATION = "rime/user/installation.yaml"
    // Today's app's names for what moved (Migration): English's learned words and imported Mozc files.
    private const val LEGACY_ENGLISH = "userdict/"
    private const val LEGACY_JAPANESE = "ext/"

    /** Folders of the app's data, by their entry prefix in a backup */
    private fun folders(context: Context) = mapOf(
        "rime/user/" to Engines.userDir(context),
        "mozc/" to Engines.mozcDir(context),
        "english/" to Data.englishDir(context),
        "ja-dictionaries/" to PersonalWords.importedDir(context),
    )

    fun fileName(time: Long) = "SebTypeSettings_${java.text.SimpleDateFormat("yyyyMMdd_HHmmss", java.util.Locale.ROOT).format(time)}.backup"

    suspend fun export(context: Context, out: OutputStream, clipboard: Boolean) = withContext(Dispatchers.IO) {
        // What Rime and Mozc hold in memory goes to their files first.
        Engines.saveJapanese()
        ZipOutputStream(out.buffered()).use { zip ->
            fun put(name: String, bytes: ByteArray) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(bytes)
                zip.closeEntry()
            }
            fun putFile(name: String, file: File) {
                if (!file.isFile) return
                zip.putNextEntry(ZipEntry(name))
                file.inputStream().use { it.copyTo(zip) }
                zip.closeEntry()
            }
            putFile(PREFS, Prefs.file(context))
            putFile(CONF, Engines.settingsFile(context))
            put(WORDS, PersonalWord.json(PersonalWords.all(context)).toByteArray())
            folders(context).forEach { (prefix, dir) ->
                dir.walkTopDown().filter { it.isFile && !it.name.endsWith(".new") && it.name != "LOCK" }.forEach { file ->
                    val name = prefix + file.relativeTo(dir).invariantSeparatorsPath
                    if (name != INSTALLATION) putFile(name, file)
                }
            }
            if (clipboard) {
                putFile(CLIPBOARD, File(context.filesDir, CLIPBOARD))
                File(context.filesDir, "clipboardfiles").listFiles().orEmpty().forEach { putFile(CLIPBOARD_FILES + it.name, it) }
            }
        }
    }

    /**
     * Restores a backup over the phone's data. Rime and Mozc are stopped meanwhile; the parts a backup doesn't
     * have (an older one's clipboard history) stay as they are. Blocks.
     */
    suspend fun import(context: Context, input: InputStream) = withContext(Dispatchers.IO) {
        val staging = File(context.cacheDir, "import").apply { deleteRecursively(); mkdirs() }
        try {
            val root = staging.canonicalPath + File.separator
            ZipInputStream(input.buffered()).use { zip ->
                generateSequence { zip.nextEntry }.filter { !it.isDirectory && it.name != INSTALLATION }.forEach { entry ->
                    val out = File(staging, entry.name)
                    if (!out.canonicalPath.startsWith(root)) throw IOException("Bad entry ${entry.name}")
                    out.parentFile!!.mkdirs()
                    out.outputStream().use { zip.copyTo(it) }
                }
            }
            restore(context, staging)
        } finally {
            staging.deleteRecursively()
        }
    }

    private suspend fun restore(context: Context, from: File) {
        File(from, PREFS).takeIf { it.isFile }?.let { file ->
            val prefs = file.source().buffer().use { PreferencesSerializer.readFrom(it) }
            Prefs.replace(context, prefs)
        }
        File(from, CONF).takeIf { it.isFile }?.let { Engines.replaceSettings(context, it.readText()) }
        File(from, WORDS).takeIf { it.isFile }?.let { file ->
            val have = PersonalWords.all(context).map { Triple(it.word, it.locale, it.shortcut) }.toSet()
            PersonalWords.add(context, PersonalWord.list(file.readText()).filter { Triple(it.word, it.locale, it.shortcut) !in have })
        }
        // Today's app's names for English's learned words and the imported Mozc files.
        File(from, LEGACY_ENGLISH).listFiles()?.forEach { moveInto(it, File(from, "english/${it.name}")) }
        File(from, LEGACY_JAPANESE).listFiles { f -> " ja " in f.name }?.forEach { moveInto(it, File(from, "ja-dictionaries/${it.name}")) }

        val folders = folders(context)
        // Mozc first, with Mozc stopped (without saving: its files are being replaced).
        File(from, "mozc").takeIf { it.isDirectory }?.let { dir ->
            val done = CountDownLatch(1)
            Engines.onThread(NativeCore.JAPANESE) {
                try {
                    NativeCore.stop(NativeCore.JAPANESE)
                    replace(dir, folders.getValue("mozc/"))
                } finally {
                    done.countDown()
                }
            }
            done.await()
        }
        File(from, "english").takeIf { it.isDirectory }?.let { replace(it, folders.getValue("english/")) }
        File(from, "ja-dictionaries").takeIf { it.isDirectory }?.let { replace(it, folders.getValue("ja-dictionaries/")) }
        File(from, "rime/user").takeIf { it.isDirectory }?.let { dir ->
            val done = CountDownLatch(1)
            // installation.yaml (never in a backup) stays: it is this phone's.
            Engines.whileChineseStopped(context, redeploy = true, block = { replace(dir, folders.getValue("rime/user/"), keep = setOf("installation.yaml")) },
                done = { done.countDown() })
            withContext(Dispatchers.IO) { done.await() }
        }
        if (File(from, CLIPBOARD).isFile) {
            File(from, CLIPBOARD).copyTo(File(context.filesDir, CLIPBOARD), overwrite = true)
            File(from, CLIPBOARD_FILES).takeIf { it.isDirectory }?.let { replace(it, File(context.filesDir, "clipboardfiles")) }
        }
        PersonalWords.refreshMozc(context)
        Log.w(TAG, "Imported a settings backup")
    }

    private fun moveInto(from: File, to: File) {
        to.parentFile!!.mkdirs()
        if (!from.renameTo(to)) throw IOException("Can't stage ${from.name}")
    }

    /** [to]'s files become [from]'s, but those named in [keep] */
    private fun replace(from: File, to: File, keep: Set<String> = emptySet()) {
        to.listFiles().orEmpty().filter { it.name !in keep }.forEach { it.deleteRecursively() }
        to.mkdirs()
        from.copyRecursively(to, overwrite = true)
    }
}
