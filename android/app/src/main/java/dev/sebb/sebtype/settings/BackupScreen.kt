package dev.sebb.sebtype.settings

import android.content.Intent
import android.text.format.DateUtils
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.graphics.Color
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
    val connection by Sync.connection.collectAsState()
    var dialog by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) { SyncAccountStore.load(context) }
        Sync.refresh(context)
        // The page shows the account's state as it is now (#452), apart from the last sync's outcome.
        if (SyncAccountStore.current.value != null) Sync.checkConnection(context)
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
        if (account != null) Item(stringResource(R.string.sebtype_settings_sync_check_test),
            connection?.let { checkText(it) }, Modifier.clickable { Sync.checkConnection(context) }) {
            connection?.let { CheckMark(it) }
        }
        if (account != null) NavItem(stringResource(R.string.sebtype_settings_sync_delete),
            stringResource(R.string.sebtype_settings_sync_delete_subtitle)) { dialog = "delete" }
    }
    when (dialog) {
        "login" -> SyncLoginDialog { dialog = null }
        "delete" -> DeleteDialog { dialog = null }
    }
}

@Composable
internal fun checkText(check: Sync.Check) = stringResource(when (check) {
    Sync.Check.Checking -> R.string.sebtype_settings_sync_check_checking
    Sync.Check.Connected -> R.string.sebtype_settings_sync_check_connected
    Sync.Check.LoginFailed -> R.string.sebtype_settings_sync_login_failed
    Sync.Check.Unreachable -> R.string.sebtype_settings_sync_check_unreachable
    Sync.Check.NotSebType -> R.string.sebtype_settings_sync_check_not_sebtype
    Sync.Check.Tls -> R.string.sebtype_settings_sync_check_tls
})

/** A check's outcome at a glance (#452): a green tick when it works, a berry X when it doesn't, nothing while checking. */
@Composable
internal fun CheckMark(check: Sync.Check, size: Dp = 24.dp) {
    if (check == Sync.Check.Checking) return
    val ok = check == Sync.Check.Connected
    val color = if (ok) Good else Berry
    // The Configurator's icons/tick.svg and cross.svg, on the same 24-unit grid.
    Canvas(Modifier.size(size)) {
        val u = this.size.width / 24f
        val stroke = Stroke(width = 2.4f * u, cap = StrokeCap.Round, join = StrokeJoin.Round)
        val path = Path().apply {
            if (ok) { moveTo(5f * u, 12.5f * u); lineTo(9.5f * u, 17f * u); lineTo(19f * u, 7.5f * u) }
            else { moveTo(6.5f * u, 6.5f * u); lineTo(17.5f * u, 17.5f * u); moveTo(17.5f * u, 6.5f * u); lineTo(6.5f * u, 17.5f * u) }
        }
        drawPath(path, color, style = stroke)
    }
}

private val Good = Color(0xFF3E8A4C)

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
    val scope = rememberCoroutineScope()
    // Save checks the address and login first (#452); a failure stays here with its reason, and Save
    // anyway keeps the login all the same (sync is opportunistic: a server down today syncs later).
    var check by remember(server, user, password) { mutableStateOf<Sync.Check?>(null) }
    val failed = check != null && check != Sync.Check.Checking && check != Sync.Check.Connected
    fun save(checked: Sync.Check) {
        // A first login turns sync on; a changed one keeps it as it was.
        val account = SyncAccount(url!!, user, password, enabled = saved?.enabled ?: true)
        Sync.setEnabled(context, account, account.enabled, checked)
        close()
    }
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
                check?.let {
                    Row(Modifier.padding(top = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        CheckMark(it, 20.dp)
                        if (it != Sync.Check.Checking) Spacer(Modifier.width(6.dp))
                        Text(checkText(it), color = if (failed) MaterialTheme.colorScheme.error else Color.Unspecified)
                    }
                }
            }
        },
        confirmButton = {
            TextButton(enabled = url != null && user.isNotEmpty() && password.isNotEmpty() && check != Sync.Check.Checking, onClick = {
                val failure = check
                if (failed) save(failure!!)
                else {
                    check = Sync.Check.Checking
                    scope.launch {
                        val result = Sync.check(SyncAccount(url!!, user, password, enabled = false))
                        if (result == Sync.Check.Connected) save(result) else check = result
                    }
                }
            }) { Text(stringResource(if (failed) R.string.sebtype_settings_sync_check_save_anyway else R.string.sebtype_settings_save)) }
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
