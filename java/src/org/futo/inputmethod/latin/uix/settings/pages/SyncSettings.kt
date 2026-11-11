package org.futo.inputmethod.latin.uix.settings.pages

import android.text.format.DateUtils
import android.widget.Toast
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.futo.inputmethod.engine.general.ChineseSync
import org.futo.inputmethod.engine.general.SyncAccount
import org.futo.inputmethod.engine.general.SyncAccountStore
import org.futo.inputmethod.latin.R
import org.futo.inputmethod.latin.uix.settings.NavigationItem
import org.futo.inputmethod.latin.uix.settings.NavigationItemStyle
import org.futo.inputmethod.latin.uix.settings.ScreenTitle
import org.futo.inputmethod.latin.uix.settings.SettingToggleRaw
import org.futo.inputmethod.latin.uix.settings.SettingsCard

// SebType (#12): sync of the learned words with the user's own server, on the Sync & backup screen.

@Composable
fun SyncSection(navController: NavHostController) {
    val context = LocalContext.current
    val account by SyncAccountStore.current.collectAsState()
    val status by ChineseSync.status.collectAsState()
    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) { SyncAccountStore.load(context) }
        ChineseSync.refresh(context)
    }

    ScreenTitle(stringResource(R.string.sebtype_settings_sync))
    SettingsCard {
        SettingToggleRaw(
            title = stringResource(R.string.sebtype_settings_sync_toggle),
            subtitle = when(val s = status) {
                ChineseSync.Status.Off -> stringResource(R.string.sebtype_settings_sync_off)
                ChineseSync.Status.NotYet -> stringResource(R.string.sebtype_settings_sync_not_yet)
                ChineseSync.Status.Syncing -> stringResource(R.string.sebtype_settings_sync_syncing)
                ChineseSync.Status.Offline -> stringResource(R.string.sebtype_settings_sync_offline)
                ChineseSync.Status.LoginFailed -> stringResource(R.string.sebtype_settings_sync_login_failed)
                is ChineseSync.Status.Synced -> stringResource(R.string.sebtype_settings_sync_synced,
                    DateUtils.formatDateTime(context, s.atMillis,
                        DateUtils.FORMAT_SHOW_DATE or DateUtils.FORMAT_SHOW_TIME or DateUtils.FORMAT_ABBREV_ALL))
            },
            enabled = account?.enabled == true,
            setValue = { on ->
                val saved = account
                if(saved == null) navController.navigate("syncLogin")
                else ChineseSync.setEnabled(context, saved, on)
            }
        )
        NavigationItem(
            title = stringResource(R.string.sebtype_settings_sync_login),
            subtitle = account?.let { "${it.user} · ${it.server.removePrefix("https://")}" }
                ?: stringResource(R.string.sebtype_settings_sync_login_none),
            style = NavigationItemStyle.Misc,
            navigate = { navController.navigate("syncLogin") }
        )
        if(account != null) NavigationItem(
            title = stringResource(R.string.sebtype_settings_sync_delete),
            subtitle = stringResource(R.string.sebtype_settings_sync_delete_subtitle),
            style = NavigationItemStyle.Misc,
            navigate = { navController.navigate("syncDelete") }
        )
    }
}

@Composable
fun SyncLoginDialog(navController: NavHostController) {
    val context = LocalContext.current
    val saved = remember { SyncAccountStore.current.value }
    var server by remember { mutableStateOf(saved?.server?.removePrefix("https://") ?: "") }
    var user by remember { mutableStateOf(saved?.user ?: "") }
    var password by remember { mutableStateOf(saved?.password ?: "") }
    val url = SyncAccount.normalizeServer(server)
    val serverInvalid = server.isNotBlank() && url == null
    AlertDialog(
        onDismissRequest = { navController.navigateUp() },
        title = { Text(stringResource(R.string.sebtype_settings_sync_login)) },
        text = {
            Column {
                OutlinedTextField(
                    value = server, onValueChange = { server = it.trim() }, singleLine = true,
                    label = { Text(stringResource(R.string.sebtype_settings_sync_server)) },
                    placeholder = { Text("sync.example.com") },
                    isError = serverInvalid,
                    supportingText = if(serverInvalid) {{ Text(stringResource(R.string.sebtype_settings_sync_server_invalid)) }} else null,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri)
                )
                OutlinedTextField(
                    value = user, onValueChange = { user = it.trim() }, singleLine = true,
                    label = { Text(stringResource(R.string.sebtype_settings_sync_user)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii),
                    modifier = Modifier.padding(top = 8.dp)
                )
                OutlinedTextField(
                    value = password, onValueChange = { password = it }, singleLine = true,
                    label = { Text(stringResource(R.string.sebtype_settings_sync_password)) },
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    modifier = Modifier.padding(top = 8.dp)
                )
            }
        },
        confirmButton = {
            TextButton(
                enabled = url != null && user.isNotEmpty() && password.isNotEmpty(),
                onClick = {
                    // A first login turns sync on; a changed one keeps it as it was.
                    val account = SyncAccount(url!!, user, password, enabled = saved?.enabled ?: true)
                    ChineseSync.setEnabled(context, account, account.enabled)
                    navController.navigateUp()
                }
            ) { Text(stringResource(R.string.sebtype_settings_save)) }
        },
        dismissButton = {
            TextButton(onClick = { navController.navigateUp() }) { Text(stringResource(android.R.string.cancel)) }
        }
    )
}

@Composable
fun SyncDeleteDialog(navController: NavHostController) {
    val context = LocalContext.current
    AlertDialog(
        onDismissRequest = { navController.navigateUp() },
        title = { Text(stringResource(R.string.sebtype_settings_sync_delete)) },
        text = { Text(stringResource(R.string.sebtype_settings_sync_delete_confirm)) },
        confirmButton = {
            TextButton(onClick = {
                val app = context.applicationContext
                ChineseSync.deleteOnServer(app) { deleted ->
                    Toast.makeText(app,
                        if(deleted) R.string.sebtype_settings_sync_deleted else R.string.sebtype_settings_sync_delete_failed,
                        Toast.LENGTH_SHORT).show()
                }
                navController.navigateUp()
            }) { Text(stringResource(R.string.sebtype_settings_sync_delete_button)) }
        },
        dismissButton = {
            TextButton(onClick = { navController.navigateUp() }) { Text(stringResource(android.R.string.cancel)) }
        }
    )
}
