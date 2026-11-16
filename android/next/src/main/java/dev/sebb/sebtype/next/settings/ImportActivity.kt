package dev.sebb.sebtype.next.settings

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.clickable
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.lifecycleScope
import dev.sebb.sebtype.next.Engines
import dev.sebb.sebtype.next.R
import dev.sebb.sebtype.next.data.Backup
import dev.sebb.sebtype.next.data.ChineseData
import dev.sebb.sebtype.next.data.Import
import dev.sebb.sebtype.next.data.PersonalWords
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

/**
 * Imports one file (#11, #34), from Sync & backup's Import, 日本語's My words or another app: a settings backup,
 * or the PCs' personal data for one language. It shows what the file is and closes once it is imported.
 */
class ImportActivity : ComponentActivity() {
    /** [head]: enough of the file to tell its kind ([Import.of]); an import reads it again from [uri]. */
    private class File(val uri: Uri, val name: String, val head: ByteArray, val kind: Import?)

    private var file by mutableStateOf<File?>(null)
    private var importing by mutableStateOf(false)

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        Engines.configure(this)
        val uri = intent.data ?: intent.getParcelableExtraCompat()
        if (uri == null) return finish()
        lifecycleScope.launch {
            file = withContext(Dispatchers.IO) {
                runCatching { contentResolver.openInputStream(uri)!!.use { head(it) } }.getOrNull()
                    ?.let { File(uri, name(uri), it, Import.of(it)) }
            }
            if (file == null) done(false)
        }
        setContent { PicnicTheme { file?.let { Content(it) } } }
    }

    private fun head(input: java.io.InputStream): ByteArray {
        val out = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(64 * 1024)
        while (out.size() < Import.HEAD_MAX) {
            val n = input.read(buffer)
            if (n < 0) break
            out.write(buffer, 0, n)
        }
        return out.toByteArray()
    }

    @Suppress("DEPRECATION")
    private fun Intent.getParcelableExtraCompat(): Uri? = getParcelableExtra(Intent.EXTRA_STREAM)

    private fun name(uri: Uri) = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
        if (it.moveToFirst()) it.getString(0) else null
    } ?: uri.lastPathSegment ?: "?"

    @Composable
    private fun Content(file: File) = Screen(file.name, ::finish) {
        val kind = file.kind
        when {
            importing -> Item("…", icon = { CircularProgressIndicator(color = Berry) })
            kind == null -> Tip(stringResource(R.string.import_unknown))
            else -> Card {
                val title = if (kind is Import.Backup) stringResource(R.string.settings_import_file)
                else stringResource(R.string.import_as, "${mapOf("zh" to "中文", "ja" to "日本語", "en" to "English")[kind.language]} (${kind.language})")
                Item(title, if (kind is Import.Backup) stringResource(R.string.import_backup_subtitle) else null,
                    Modifier.clickable { start(file, kind) })
            }
        }
    }

    private fun start(file: File, kind: Import) {
        importing = true
        val app = applicationContext
        lifecycleScope.launch {
            fun open() = app.contentResolver.openInputStream(file.uri)!!
            val ok = runCatching {
                when (kind) {
                    Import.Backup -> open().use { Backup.import(app, it) }
                    Import.RimeWordList -> {
                        val bytes = withContext(Dispatchers.IO) { open().use { it.readBytes() } }
                        check(suspendCoroutine { c -> ChineseData.importWordList(app, bytes.inputStream()) { c.resume(it) } })
                    }
                    Import.RimeLearnedWords -> check(withContext(Dispatchers.IO) { open().use { ChineseData.importLearnedWords(app, it) } })
                    Import.MozcDictionary -> withContext(Dispatchers.IO) {
                        PersonalWords.importJapanese(app, file.name, open().use { it.readBytes() })
                    }
                    is Import.EnglishWords -> withContext(Dispatchers.IO) {
                        val have = PersonalWords.all(app).map { it.word to it.locale }.toSet()
                        PersonalWords.add(app, kind.words.filter { (it.word to it.locale) !in have })
                    }
                }
            }.onFailure { android.util.Log.w(Engines.TAG, "Import of ${file.name} failed", it) }.isSuccess
            done(ok)
        }
    }

    private fun done(ok: Boolean) {
        Toast.makeText(applicationContext, if (ok) R.string.import_done else R.string.import_failed, Toast.LENGTH_SHORT).show()
        finish()
    }
}
