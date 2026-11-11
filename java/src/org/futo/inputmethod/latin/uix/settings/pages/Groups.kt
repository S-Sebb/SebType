package org.futo.inputmethod.latin.uix.settings.pages

import android.content.Context
import android.content.pm.PackageManager
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.selection.selectable
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.core.content.ContextCompat
import androidx.navigation.NavHostController
import com.google.common.base.Optional
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.futo.inputmethod.engine.general.ChineseLearnedWords
import org.futo.inputmethod.engine.general.RimeIceSetup
import org.futo.inputmethod.engine.general.initJniDictLocations
import org.futo.inputmethod.latin.R
import org.futo.inputmethod.latin.personalization.PersonalizationHelper
import org.futo.inputmethod.latin.settings.Settings
import org.futo.inputmethod.latin.uix.SettingsExporter
import org.futo.inputmethod.latin.uix.findSettingsActivity
import org.futo.inputmethod.latin.uix.actions.clipboard.ClipboardHistoryEnabled
import org.futo.inputmethod.latin.uix.actions.clipboard.ClipboardHistoryItemsToKeep
import org.futo.inputmethod.latin.uix.actions.clipboard.ClipboardHistoryTimeToKeep
import org.futo.inputmethod.latin.uix.actions.clipboard.ClipboardSaveImages
import org.futo.inputmethod.latin.uix.actions.clipboard.ClipboardSaveScreenshots
import org.futo.inputmethod.latin.uix.actions.clipboard.ScreenshotHelper
import org.futo.inputmethod.latin.uix.settings.SettingsCard
import org.futo.inputmethod.latin.uix.settings.BottomSpacer
import org.futo.inputmethod.latin.uix.settings.NavigationItem
import org.futo.inputmethod.latin.uix.settings.NavigationItemStyle
import org.futo.inputmethod.latin.uix.settings.ScreenTitle
import org.futo.inputmethod.latin.uix.settings.ScrollableList
import org.futo.inputmethod.latin.uix.settings.SettingCheckbox
import org.futo.inputmethod.latin.uix.settings.SettingItem
import org.futo.inputmethod.latin.uix.settings.SettingSlider
import org.futo.inputmethod.latin.uix.settings.SettingToggleDataStore
import org.futo.inputmethod.latin.uix.settings.SettingToggleRaw
import org.futo.inputmethod.latin.uix.settings.SettingToggleSharedPrefs
import org.futo.inputmethod.latin.uix.settings.useDataStore
import org.futo.inputmethod.latin.uix.settings.useDataStoreValue
import org.futo.inputmethod.nativelib.mozc.session.SessionExecutor
import org.futo.inputmethod.nativelib.mozc.session.SessionHandlerFactory

// SebType's Privacy and Sync & backup groups (#41). Keyboard is KeyboardSettingsMenu (Typing.kt),
// About is AboutMenu (Help.kt), Languages is LanguagesGroup.kt.

@Composable
private fun clipboardKeepSummary(): String {
    val items = useDataStoreValue(ClipboardHistoryItemsToKeep)
    val hours = useDataStoreValue(ClipboardHistoryTimeToKeep)
    val time = if(hours % 24 == 0) stringResource(R.string.sebtype_settings_days, hours / 24)
        else stringResource(R.string.sebtype_settings_hours, hours)
    return stringResource(R.string.sebtype_settings_clipboard_items, items) + " · " + time
}

/** One switch for FUTO's two: saving copied images, and screenshots (which needs the photos permission). */
@Composable
private fun SaveImagesToggle() {
    val context = LocalContext.current
    val (images, setImages) = useDataStore(ClipboardSaveImages)
    val (screenshots, setScreenshots) = useDataStore(ClipboardSaveScreenshots)
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        setScreenshots(it)
    }
    SettingToggleRaw(
        title = stringResource(R.string.sebtype_settings_clipboard_images),
        enabled = images || screenshots,
        setValue = { on ->
            setImages(on)
            if(!on) setScreenshots(false)
            else if(ContextCompat.checkSelfPermission(context, ScreenshotHelper.permission) == PackageManager.PERMISSION_GRANTED) setScreenshots(true)
            else launcher.launch(ScreenshotHelper.permission)
        }
    )
}

@Composable
fun PrivacyScreen(navController: NavHostController) {
    var keepExpanded by remember { mutableStateOf(false) }
    ScrollableList {
        ScreenTitle(stringResource(R.string.sebtype_settings_privacy), showBack = true, navController)
        SettingsCard {
            SettingToggleSharedPrefs(
                title = stringResource(R.string.sebtype_settings_learn),
                subtitle = stringResource(R.string.sebtype_settings_learn_subtitle),
                key = Settings.PREF_KEY_USE_PERSONALIZED_DICTS,
                default = true
            )
            // SebType (#31): the same switch as the action bar's incognito button.
            SettingToggleSharedPrefs(
                title = stringResource(R.string.sebtype_incognito),
                subtitle = stringResource(R.string.sebtype_incognito_subtitle),
                key = Settings.PREF_SEBTYPE_INCOGNITO,
                default = false
            )
        }

        ScreenTitle(stringResource(R.string.sebtype_settings_clipboard))
        SettingsCard {
            SettingToggleDataStore(
                title = stringResource(R.string.sebtype_settings_clipboard_keep_history),
                setting = ClipboardHistoryEnabled
            )
            if(useDataStoreValue(ClipboardHistoryEnabled)) {
                SettingItem(
                    title = stringResource(R.string.sebtype_settings_clipboard_keep),
                    onClick = { keepExpanded = !keepExpanded }
                ) {
                    Text(clipboardKeepSummary())
                }
                if(keepExpanded) {
                    SettingSlider(
                        stringResource(R.string.action_clipboard_manager_settings_maximum_clips),
                        ClipboardHistoryItemsToKeep,
                        range = 0.0f..100.0f,
                        hardRange = 0.0f..Float.POSITIVE_INFINITY,
                        transform = { it.toInt() },
                    )
                    SettingSlider(
                        stringResource(R.string.action_clipboard_manager_settings_hours_to_keep_clips),
                        ClipboardHistoryTimeToKeep,
                        range = 1.0f..336.0f,
                        hardRange = 0.0f..Float.POSITIVE_INFINITY,
                        transform = { it.toInt() },
                    )
                }
                SaveImagesToggle()
            }

            NavigationItem(
                title = stringResource(R.string.sebtype_settings_forget),
                subtitle = stringResource(R.string.sebtype_settings_forget_subtitle),
                style = NavigationItemStyle.Misc,
                navigate = { navController.navigate("forgetLearned") }
            )
        }
        BottomSpacer()
    }
}

object LearnedWords {
    /** Deletes what [language] ("en", "zh" or "ja") learned from typing; the user's own words stay. */
    suspend fun forget(context: Context, language: String) = withContext(Dispatchers.IO) {
        val app = context.applicationContext
        when(language) {
            "en" -> PersonalizationHelper.removeAllUserHistoryDictionaries(app)
            "zh" -> {
                // Starts Rime again only if it was running; otherwise it starts when Chinese is next typed.
                val wasReady = RimeIceSetup.state.value == RimeIceSetup.State.Ready
                ChineseLearnedWords.forget(app)
                if(wasReady) RimeIceSetup.prepareInBackground(app)
            }
            "ja" -> {
                // The process's Mozc, shared with the Japanese keyboard when it is running.
                initJniDictLocations(app)
                SessionExecutor.getInstanceInitializedIfNecessary(SessionHandlerFactory(Optional.absent()), app).apply {
                    clearUserHistory()
                    clearUserPrediction()
                    syncData()
                }
            }
        }
    }
}

@Composable
fun ForgetLearnedDialog(navController: NavHostController) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var language by remember { mutableStateOf("en") }
    AlertDialog(
        onDismissRequest = { navController.navigateUp() },
        title = { Text(stringResource(R.string.sebtype_settings_forget)) },
        text = {
            Column {
                Text(stringResource(R.string.sebtype_settings_forget_confirm))
                listOf("en" to "English", "zh" to "中文", "ja" to "日本語").forEach { (code, name) ->
                    SettingItem(
                        title = name,
                        compact = true,
                        modifier = Modifier.selectable(language == code) { language = code },
                        icon = { RadioButton(selected = language == code, onClick = null) }
                    ) {}
                }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                val chosen = language
                scope.launch {
                    LearnedWords.forget(context, chosen)
                    Toast.makeText(context, R.string.sebtype_settings_forgotten, Toast.LENGTH_SHORT).show()
                }
                navController.navigateUp()
            }) { Text(stringResource(R.string.sebtype_settings_forget_button)) }
        },
        dismissButton = {
            TextButton(onClick = { navController.navigateUp() }) { Text(stringResource(android.R.string.cancel)) }
        }
    )
}

@Composable
fun BackupScreen(navController: NavHostController) {
    val context = LocalContext.current
    val includeClipboard = remember { findSettingsActivity(context)!!.exportIncludesClipboard }
    ScrollableList {
        ScreenTitle(stringResource(R.string.sebtype_settings_backup), showBack = true, navController)
        ScreenTitle(stringResource(R.string.sebtype_settings_settings_file))
        SettingsCard {
            SettingCheckbox(
                title = stringResource(R.string.sebtype_settings_export_clipboard),
                checked = includeClipboard.value,
                setChecked = { includeClipboard.value = it }
            )
            NavigationItem(
                title = stringResource(R.string.sebtype_settings_export),
                subtitle = stringResource(R.string.sebtype_settings_export_subtitle),
                style = NavigationItemStyle.Misc,
                navigate = { navController.navigate("exportingcfg") }
            )
            NavigationItem(
                title = stringResource(R.string.sebtype_settings_import),
                subtitle = stringResource(R.string.settings_import_configuration_subtitle),
                style = NavigationItemStyle.Misc,
                navigate = { SettingsExporter.triggerImportSettings(context) }
            )
        }
        BottomSpacer()
    }
}
