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
            if (Prefs.file(context).isFile) put(PREFS, Prefs.exported(context))
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

    /**
     * Reads all of the backup before it changes anything, and puts everything back if a step fails: the
     * options, the personal dictionary and the folders, which change with the engines that use them stopped.
     */
    private suspend fun restore(context: Context, from: File) {
        val originals = File(context.filesDir, "restore-originals")
        // An earlier import that couldn't put all of the phone's files back finishes that first, or this one doesn't start.
        if (Swap(originals).pending) whileStopped(context, listOf(NativeCore.CHINESE, NativeCore.JAPANESE, NativeCore.ENGLISH)) { Swap(originals).rollback() }
        val prefs = File(from, PREFS).takeIf { it.isFile }?.let { file -> file.source().buffer().use { PreferencesSerializer.readFrom(it) } }
        val conf = File(from, CONF).takeIf { it.isFile }?.readText()
        val have = PersonalWords.all(context)
        val words = File(from, WORDS).takeIf { it.isFile }?.let { file ->
            val keys = have.map { Triple(it.word, it.locale, it.shortcut) }.toSet()
            PersonalWord.list(file.readText()).filter { Triple(it.word, it.locale, it.shortcut) !in keys }
        }
        // Today's app's names for English's learned words and the imported Mozc files.
        File(from, LEGACY_ENGLISH).listFiles()?.forEach { moveInto(it, File(from, "english/${it.name}")) }
        File(from, LEGACY_JAPANESE).listFiles { f -> " ja " in f.name }?.forEach { moveInto(it, File(from, "ja-dictionaries/${it.name}")) }
        val dirs = folders(context).mapNotNull { (prefix, dir) -> File(from, prefix).takeIf { it.isDirectory }?.let { prefix to (it to dir) } }.toMap()
        val clipboard = File(from, CLIPBOARD).takeIf { it.isFile }
        if (prefs == null && conf == null && words == null && dirs.isEmpty() && clipboard == null) throw IOException("Not a SebType backup")

        val oldConf = Engines.settingsFile(context).takeIf { it.isFile }?.readText()
        val swap = Swap(originals.apply { deleteRecursively() }) // nothing left to put back: an empty or half-made folder
        var imported: Prefs.Imported? = null
        val stop = listOf("rime/user/" to NativeCore.CHINESE, "mozc/" to NativeCore.JAPANESE, "english/" to NativeCore.ENGLISH)
            .filter { it.first in dirs }.map { it.second }
        try {
            imported = prefs?.let { Prefs.import(context, it) }
            conf?.let { Engines.replaceSettings(context, it) }
            words?.let { PersonalWords.add(context, it) }
            // 中文 set up again on the backup's data, or the originals go back (with it stopped once more).
            whileStopped(context, stop) {
                // installation.yaml (never in a backup) stays: it is this phone's.
                dirs.forEach { (prefix, dir) -> swap.replace(dir.first, dir.second, if (prefix == "rime/user/") setOf("installation.yaml") else emptySet()) }
                if (clipboard != null) {
                    swap.replaceFile(clipboard, File(context.filesDir, CLIPBOARD))
                    File(from, CLIPBOARD_FILES).takeIf { it.isDirectory }?.let { swap.replace(it, File(context.filesDir, "clipboardfiles")) }
                }
            }
        } catch (e: Throwable) {
            if (swap.pending) runCatching { whileStopped(context, stop) { swap.rollback() } }.onFailure { Log.w(TAG, "Putting the phone's data back", it) }
            imported?.let { Prefs.undo(context, it) }
            oldConf?.let { Engines.replaceSettings(context, it) }
            words?.let { PersonalWords.delete(context, *it.toTypedArray()) }
            Log.w(TAG, "A settings backup failed to import; the phone's data is as it was")
            throw e
        }
        swap.commit()
        PersonalWords.refreshMozc(context)
        Log.w(TAG, "Imported a settings backup")
    }

    /**
     * Runs [block] with the engines in [langs] stopped, each on its own thread, and waits for it; [block]'s
     * failure, or 中文 not coming back after it, is thrown here. Mozc stops without saving (its files are
     * being replaced), English saves first, and 中文 is set up again after. A stopped engine starts again
     * when next used.
     */
    private fun whileStopped(context: Context, langs: List<Int>, block: () -> Unit) {
        if (langs.isEmpty()) return block()
        val rest = langs.drop(1)
        val done = CountDownLatch(1)
        var failure: Throwable? = null
        val inner = {
            try {
                if (langs[0] != NativeCore.CHINESE) NativeCore.stop(langs[0])
                whileStopped(context, rest, block)
            } catch (e: Throwable) {
                failure = e
            }
        }
        when (langs[0]) {
            NativeCore.CHINESE -> Engines.whileChineseStopped(context, redeploy = true, block = inner, done = { ready ->
                if (failure == null && !ready) failure = IOException("中文 didn't start on the restored data")
                done.countDown()
            })
            NativeCore.JAPANESE -> Engines.onThread(NativeCore.JAPANESE) { inner(); done.countDown() }
            // English types on NativeCore's thread, which starts it again for a key.
            else -> NativeCore.post { inner(); done.countDown() }
        }
        done.await()
        failure?.let { throw it }
    }

    private fun moveInto(from: File, to: File) {
        to.parentFile!!.mkdirs()
        if (!from.renameTo(to)) throw IOException("Can't stage ${from.name}")
    }

    /**
     * Replaces folders and files, keeping what they held in [originals] until [commit], or putting it back
     * ([rollback]). What is left to put back is on disk, so a rollback that stopped partway finishes later
     * with a new Swap on the same folder ([pending]). Step n keeps its originals in n/, their place in n.to
     * (the folder, then "all" but the names after it, or "one", the name after it), and n.copied while the
     * backup's files may be in that place.
     */
    internal class Swap(private val originals: File, private val rename: (File, File) -> Boolean = File::renameTo) {
        private fun steps() = originals.list().orEmpty().filter { it.endsWith(".to") }.map { it.removeSuffix(".to").toInt() }

        val pending get() = steps().isNotEmpty()

        /** [to]'s files become [from]'s, but those named in [keep] */
        fun replace(from: File, to: File, keep: Set<String> = emptySet()) {
            if (!from.isDirectory) throw IOException("Can't read ${from.name}")
            to.mkdirs()
            val n = step(to, "all", keep)
            to.listFiles().orEmpty().filter { it.name !in keep }.forEach { move(it, File(originals, "$n/${it.name}")) }
            File(originals, "$n.copied").createNewFile()
            from.copyRecursively(to, overwrite = true)
        }

        fun replaceFile(from: File, to: File) {
            val n = step(to.parentFile!!, "one", setOf(to.name))
            if (to.exists()) move(to, File(originals, "$n/${to.name}"))
            File(originals, "$n.copied").createNewFile()
            from.copyTo(to, overwrite = true)
        }

        private fun step(place: File, kind: String, names: Set<String>): Int {
            val n = (steps().maxOrNull() ?: -1) + 1
            File(originals, "$n").mkdirs()
            File(originals, "$n.to").writeText((listOf(place.path, kind) + names).joinToString("\n"))
            return n
        }

        /** Puts back what was moved aside, over what came in its place, latest first; each part once. */
        fun rollback() {
            for (n in steps().sortedDescending()) {
                val (path, kind) = File(originals, "$n.to").readLines()
                val names = File(originals, "$n.to").readLines().drop(2).toSet()
                val place = File(path)
                val copied = File(originals, "$n.copied")
                if (copied.exists()) {
                    val came = if (kind == "all") place.listFiles().orEmpty().filter { it.name !in names } else names.map { File(place, it) }
                    if (!came.all { !it.exists() || it.deleteRecursively() } || !copied.delete()) throw IOException("Can't clear ${place.path}")
                }
                File(originals, "$n").listFiles().orEmpty().forEach { move(it, File(place, it.name)) }
                File(originals, "$n").delete()
                File(originals, "$n.to").delete()
            }
            commit()
        }

        /**
         * Drops the originals. The folder is renamed away in one step first, so a cleanup cut short (the
         * process killed) is never taken for a rollback still to do, which would undo a finished import.
         */
        fun commit() {
            val dropped = File(originals.parentFile, "${originals.name}-dropped").apply { deleteRecursively() }
            if (originals.exists() && !originals.renameTo(dropped)) {
                // Can't rename: forget the steps before their originals, for the same reason.
                originals.listFiles { f -> f.name.endsWith(".to") }.orEmpty().forEach { it.delete() }
                originals.deleteRecursively()
            }
            dropped.deleteRecursively()
        }

        private fun move(from: File, to: File) {
            if (!rename(from, to)) throw IOException("Can't move ${from.path}")
        }
    }
}
