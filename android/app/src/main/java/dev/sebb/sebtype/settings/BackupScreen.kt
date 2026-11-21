package dev.sebb.sebtype.settings

import android.content.Intent
import android.text.format.DateUtils
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import dev.sebb.sebtype.R
import dev.sebb.sebtype.data.Backup
import dev.sebb.sebtype.sync.Sync
import dev.sebb.sebtype.sync.SyncAccount
import dev.sebb.sebtype.sync.SyncAccountStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Sync & backup (#12, #34): the sync with the user's own server, then the settings file. */
@Composable
fun BackupScreen(nav: Nav) = Screen(stringResource(R.string.sebtype_settings_backup), nav::back) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var clipboard by rememberSaveable { mutableStateOf(false) }
    val export = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        val app = context.applicationContext
        val withClipboard = clipboard
        scope.launch {
            val ok = runCatching {
                app.contentResolver.openOutputStream(uri)!!.use { Backup.export(app, it, withClipboard) }
            }.isSuccess
            Toast.makeText(app, if (ok) R.string.export_done else R.string.export_failed, Toast.LENGTH_SHORT).show()
        }
    }
    val import = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) context.startActivity(Intent(context, ImportActivity::class.java).setData(uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
    }

    SyncSection()
    SectionTag(stringResource(R.string.sebtype_settings_settings_file))
    Card {
        CheckItem(stringResource(R.string.sebtype_settings_export_clipboard), clipboard) { clipboard = it }
        NavItem(stringResource(R.string.sebtype_settings_export), stringResource(R.string.sebtype_settings_export_subtitle)) {
            export.launch(Backup.fileName(System.currentTimeMillis()))
        }
        NavItem(stringResource(R.string.sebtype_settings_import), stringResource(R.string.sebtype_settings_import_subtitle)) {
            import.launch(arrayOf("*/*"))
        }
    }
}

@Composable
private fun SyncSection() {
    val context = LocalContext.current
    val account by SyncAccountStore.current.collectAsState()
    val status by Sync.status.collectAsState()
    var dialog by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) { SyncAccountStore.load(context) }
        Sync.refresh(context)
    }
    SectionTag(stringResource(R.string.sebtype_settings_sync))
    Card {
        SwitchItem(
            stringResource(R.string.sebtype_settings_sync_toggle),
            when (val s = status) {
                Sync.Status.Off -> stringResource(R.string.sebtype_settings_sync_off)
                Sync.Status.NotYet -> stringResource(R.string.sebtype_settings_sync_not_yet)
                Sync.Status.Syncing -> stringResource(R.string.sebtype_settings_sync_syncing)
                Sync.Status.Offline -> stringResource(R.string.sebtype_settings_sync_offline)
                Sync.Status.LoginFailed -> stringResource(R.string.sebtype_settings_sync_login_failed)
                is Sync.Status.Synced -> stringResource(R.string.sebtype_settings_sync_synced, DateUtils.formatDateTime(context,
                    s.atMillis, DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_SHOW_TIME or DateUtils.FORMAT_ABBREV_ALL))
            },
            account?.enabled == true,
        ) { on ->
            val saved = account
            if (saved == null) dialog = "login" else Sync.setEnabled(context, saved, on)
        }
        NavItem(stringResource(R.string.sebtype_settings_sync_login),
            account?.summary() ?: stringResource(R.string.sebtype_settings_sync_login_none)) {
            dialog = "login"
        }
        if (account != null) NavItem(stringResource(R.string.sebtype_settings_sync_delete),
            stringResource(R.string.sebtype_settings_sync_delete_subtitle)) { dialog = "delete" }
    }
    when (dialog) {
        "login" -> SyncLoginDialog { dialog = null }
        "delete" -> DeleteDialog { dialog = null }
    }
}

internal fun SyncAccount.summary() = "$user · ${server.removePrefix("https://")}"

@Composable
internal fun SyncLoginDialog(close: () -> Unit) {
    val context = LocalContext.current
    val saved = remember { SyncAccountStore.current.value }
    var server by rememberSaveable { mutableStateOf(saved?.server?.removePrefix("https://") ?: "") }
    var user by rememberSaveable { mutableStateOf(saved?.user ?: "") }
    // Keep password in process memory only (not serialized to system_server's savedInstanceState).
    var password by remember { mutableStateOf(saved?.password ?: "") }
    val url = SyncAccount.normalizeServer(server)
    val invalid = server.isNotBlank() && url == null
    AlertDialog(
        onDismissRequest = close,
        title = { Text(stringResource(R.string.sebtype_settings_sync_login)) },
        text = {
            Column {
                OutlinedTextField(
                    server, { server = it.trim() }, singleLine = true,
                    label = { Text(stringResource(R.string.sebtype_settings_sync_server)) },
                    placeholder = { Text("sync.example.com") },
                    isError = invalid,
                    supportingText = if (invalid) {{ Text(stringResource(R.string.sebtype_settings_sync_server_invalid)) }} else null,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                )
                OutlinedTextField(
                    user, { user = it.trim() }, singleLine = true,
                    label = { Text(stringResource(R.string.sebtype_settings_sync_user)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii),
                    modifier = Modifier.padding(top = 8.dp),
                )
                OutlinedTextField(
                    password, { password = it }, singleLine = true,
                    label = { Text(stringResource(R.string.sebtype_settings_sync_password)) },
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    modifier = Modifier.padding(top = 8.dp),
                )
            }
        },
        confirmButton = {
            TextButton(enabled = url != null && user.isNotEmpty() && password.isNotEmpty(), onClick = {
                // A first login turns sync on; a changed one keeps it as it was.
                val account = SyncAccount(url!!, user, password, enabled = saved?.enabled ?: true)
                Sync.setEnabled(context, account, account.enabled)
                close()
            }) { Text(stringResource(R.string.sebtype_settings_save)) }
        },
        dismissButton = { TextButton(onClick = close) { Text(stringResource(android.R.string.cancel)) } },
    )
}

@Composable
private fun DeleteDialog(close: () -> Unit) {
    val context = LocalContext.current
    AlertDialog(
        onDismissRequest = close,
        title = { Text(stringResource(R.string.sebtype_settings_sync_delete)) },
        text = { Text(stringResource(R.string.sebtype_settings_sync_delete_confirm)) },
        confirmButton = {
            TextButton(onClick = {
                val app = context.applicationContext
                Sync.deleteOnServer(app) { deleted ->
                    Toast.makeText(app, if (deleted) R.string.sebtype_settings_sync_deleted else R.string.sebtype_settings_sync_delete_failed,
                        Toast.LENGTH_SHORT).show()
                }
                close()
            }) { Text(stringResource(R.string.sebtype_settings_sync_delete_button)) }
        },
        dismissButton = { TextButton(onClick = close) { Text(stringResource(android.R.string.cancel)) } },
    )
}
