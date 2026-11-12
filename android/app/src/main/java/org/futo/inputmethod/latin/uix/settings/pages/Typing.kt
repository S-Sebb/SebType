package org.futo.inputmethod.latin.uix.settings.pages

import android.content.Context
import android.media.AudioManager
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.LocalTextInputService
import androidx.compose.ui.res.booleanResource
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.input.ImeOptions
import androidx.compose.ui.text.input.PlatformImeOptions
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.input.TextInputSession
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.floatPreferencesKey
import androidx.datastore.preferences.core.intPreferencesKey
import androidx.navigation.NavHostController
import androidx.navigation.compose.rememberNavController
import kotlinx.coroutines.delay
import org.futo.inputmethod.latin.R
import org.futo.inputmethod.latin.settings.Settings
import org.futo.inputmethod.latin.settings.Settings.PREF_KEYPRESS_SOUND_VOLUME
import org.futo.inputmethod.latin.settings.Settings.PREF_VIBRATION_DURATION_SETTINGS
import org.futo.inputmethod.latin.settings.name
import org.futo.inputmethod.latin.uix.AndroidTextInput
import org.futo.inputmethod.latin.uix.KeyHintsSetting
import org.futo.inputmethod.latin.uix.SettingsKey
import org.futo.inputmethod.latin.uix.setSettingBlocking
import org.futo.inputmethod.latin.uix.settings.LocalSharedPrefsCache
import org.futo.inputmethod.latin.uix.settings.NavigationItemStyle
import org.futo.inputmethod.latin.uix.settings.ScreenTitle
import org.futo.inputmethod.latin.uix.settings.ScrollableList
import org.futo.inputmethod.latin.uix.settings.SettingSlider
import org.futo.inputmethod.latin.uix.settings.SettingSliderSharedPrefsInt
import org.futo.inputmethod.latin.uix.settings.SyncDataStoreToPreferencesFloat
import org.futo.inputmethod.latin.uix.settings.SyncDataStoreToPreferencesInt
import org.futo.inputmethod.latin.uix.settings.Tip
import org.futo.inputmethod.latin.uix.settings.UserSetting
import org.futo.inputmethod.latin.uix.settings.UserSettingsMenu
import org.futo.inputmethod.latin.uix.settings.render
import org.futo.inputmethod.latin.uix.settings.userSettingDecorationOnly
import org.futo.inputmethod.latin.uix.settings.userSettingNavigationItem
import org.futo.inputmethod.latin.uix.settings.userSettingToggleDataStore
import org.futo.inputmethod.latin.uix.settings.userSettingToggleSharedPrefs
import org.futo.inputmethod.latin.uix.theme.Typography
import org.futo.inputmethod.v2keyboard.KeyboardSettings
import kotlin.math.roundToInt

val vibrationDurationSetting = SettingsKey(
    intPreferencesKey("vibration_duration"),
    -1
)

val keySoundVolumeSetting = SettingsKey(
    floatPreferencesKey("key_sound_volume"),
    0.0f
)

val ActionBarDisplayedSetting = SettingsKey(
    booleanPreferencesKey("enable_action_bar"),
    true
)

val InlineAutofillSetting = SettingsKey(
    booleanPreferencesKey("inline_autofill"),
    true
)

val ResizeMenuLite = UserSettingsMenu(
    title = R.string.size_settings_title,
    navPath = "resize", registerNavPath = false,
    settings = listOf(
        userSettingNavigationItem(
            title = R.string.size_settings_reset,
            subtitle = R.string.size_settings_reset_subtitle,
            style = NavigationItemStyle.Misc,
            icon = R.drawable.close,
            navigate = { nav ->
                KeyboardSettings.values.forEach {
                    nav.context.setSettingBlocking(it.key, it.default)
                }
            }
        )
    )
)

@OptIn(ExperimentalLayoutApi::class)
@Preview(showBackground = true)
@Composable
fun ResizeScreen(navController: NavHostController = rememberNavController()) {
    val textInputService = LocalTextInputService.current
    val session = remember { mutableStateOf<TextInputSession?>(null) }

    DisposableEffect(Unit) {
        session.value = textInputService?.startInput(
            TextFieldValue(""),
            imeOptions = ImeOptions.Default.copy(
                platformImeOptions = PlatformImeOptions(
                    privateImeOptions = "org.futo.inputmethod.latin.ResizeMode=1"
                )
            ),
            onEditCommand = { },
            onImeActionPerformed = { }
        )

        onDispose {
            textInputService?.stopInput(session.value ?: return@onDispose)
        }
    }

    Box {
        ScrollableList {
            ScreenTitle(stringResource(R.string.size_settings_title), showBack = true, navController)

            PaymentSurface(
                isPrimary = false,
            ) {
                PaymentSurfaceHeading(title = stringResource(R.string.settings_tip))

                Text(
                    buildAnnotatedString {
                        append(stringResource(R.string.size_settings_keyboard_modes_tip))
                        append(" ")
                        appendInlineContent("icon")
                        appendLine()
                        append(stringResource(R.string.size_settings_keyboard_modes_portrait_landscape_tip))
                        appendLine()
                        append(stringResource(R.string.size_settings_resize_tip))
                    },
                    style = Typography.Body.MediumMl,
                    color = LocalContentColor.current,
                    inlineContent = mapOf(
                        "icon" to InlineTextContent(
                            Placeholder(
                                width = with(LocalDensity.current) { 24.dp.toPx().toSp() },
                                height = with(LocalDensity.current) { 24.dp.toPx().toSp() },
                                placeholderVerticalAlign = PlaceholderVerticalAlign.Center
                            )
                        ){
                            Icon(painterResource(R.drawable.keyboard_gear), contentDescription = null)
                        }
                    ))
            }

            Spacer(Modifier.height(8.dp))
            ResizeMenuLite.render(showTitle = false)

            AndroidTextInput(allowPredictions = false, customOptions = setOf("org.futo.inputmethod.latin.ResizeMode"), autoshow = false)
        }
    }
}

// SebType's Keyboard group (#41): size, number row, symbol hints and long-press delay, then key
// feedback and the action bar buttons. FUTO's other keyboard, typing and long-press options keep
// their defaults.
val KeyboardSettingsMenu = UserSettingsMenu(
    title = R.string.keyboard_settings_title,
    navPath = "keyboard", registerNavPath = true,
    settings = listOf(
        userSettingNavigationItem(
            title = R.string.sebtype_settings_size,
            subtitle = R.string.sebtype_settings_size_subtitle,
            style = NavigationItemStyle.Misc,
            navigateTo = "resize",
            icon = R.drawable.maximize
        ),
        userSettingToggleSharedPrefs(
            title = R.string.keyboard_settings_show_number_row,
            subtitle = R.string.keyboard_settings_show_number_row_subtitle,
            key = Settings.PREF_ENABLE_NUMBER_ROW,
            default = {false},
            icon = { Text("123", style = Typography.Body.MediumMl, color = MaterialTheme.colorScheme.onBackground.copy(alpha = 0.75f),
                modifier = Modifier.clearAndSetSemantics{}) }
        ),
        userSettingToggleDataStore(
            title = R.string.morekey_settings_show_hints,
            subtitle = R.string.morekey_settings_show_hints_subtitle,
            setting = KeyHintsSetting
        ),
        UserSetting(
            name = R.string.morekey_settings_duration,
            subtitle = R.string.morekey_settings_duration_subtitle,
        ) {
            val resources = LocalResources.current
            SettingSliderSharedPrefsInt(
                title = stringResource(R.string.morekey_settings_duration),
                subtitle = stringResource(R.string.morekey_settings_duration_subtitle),
                key = Settings.PREF_KEY_LONGPRESS_TIMEOUT,
                default = 300,
                range = 100.0f..700.0f,
                hardRange = 25.0f..1200.0f,
                transform = { it.roundToInt() },
                indicator = { resources.getString(R.string.abbreviation_unit_milliseconds, "$it") },
                steps = 23
            )
        },

        userSettingDecorationOnly {
            ScreenTitle(stringResource(R.string.sebtype_settings_feedback))
        },
        userSettingToggleSharedPrefs(
            title = R.string.popup_on_keypress,
            key = Settings.PREF_POPUP_ON,
            default = {booleanResource(R.bool.config_default_key_preview_popup)}
        ),
        userSettingToggleSharedPrefs(
            title = R.string.vibrate_on_keypress,
            key = Settings.PREF_VIBRATE_ON,
            default = {booleanResource(R.bool.config_default_vibration_enabled)}
        ),
        UserSetting(
            name = R.string.typing_settings_vibration_strength,
            visibilityCheck = {
                LocalSharedPrefsCache.current!!.currSharedPrefs.getBoolean(
                    Settings.PREF_VIBRATE_ON,
                    booleanResource(R.bool.config_default_vibration_enabled)
                )
            },
            component = {
                val context = LocalContext.current
                val resources = LocalResources.current
                SyncDataStoreToPreferencesInt(vibrationDurationSetting, PREF_VIBRATION_DURATION_SETTINGS)

                SettingSlider(
                    title = stringResource(R.string.typing_settings_vibration_strength),
                    setting = vibrationDurationSetting,
                    range = -1.0f .. 100.0f,
                    hardRange = -1.0f .. 2000.0f,
                    transform = { it.roundToInt() },
                    indicator = {
                        if(it == -1) {
                            resources.getString(R.string.typing_settings_vibration_strength_default)
                        } else {
                            resources.getString(R.string.abbreviation_unit_milliseconds, "$it")
                        }
                    }
                )
            }
        ),
        userSettingToggleSharedPrefs(
            title = R.string.sound_on_keypress,
            key = Settings.PREF_SOUND_ON,
            default = {booleanResource(R.bool.config_default_sound_enabled)}
        ),
        UserSetting(
            name = R.string.typing_settings_keypress_sound_volume,
            visibilityCheck = {
                LocalSharedPrefsCache.current!!.currSharedPrefs.getBoolean(
                    Settings.PREF_SOUND_ON,
                    booleanResource(R.bool.config_default_sound_enabled)
                )
            },
            component = {
                val context = LocalContext.current
                val resources = LocalResources.current
                SyncDataStoreToPreferencesFloat(keySoundVolumeSetting, PREF_KEYPRESS_SOUND_VOLUME)

                val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
                val value = remember { mutableFloatStateOf(0.0f) }
                val ringerMode = remember { mutableStateOf(audioManager.getRingerMode() == AudioManager.RINGER_MODE_NORMAL) }
                val firstPlayback = remember { mutableStateOf(false) }

                LaunchedEffect(value.floatValue) {
                    delay(100L) // debounce
                    if(firstPlayback.value == false) {
                        firstPlayback.value = true
                        return@LaunchedEffect
                    }
                    val volume = value.floatValue.let {
                        if(it == -1.0f) {
                            Settings.readDefaultKeypressSoundVolume(resources)
                        } else {
                            it
                        }
                    }

                    val shouldPlay = audioManager.getRingerMode() == AudioManager.RINGER_MODE_NORMAL
                    ringerMode.value = shouldPlay

                    if(shouldPlay) {
                        audioManager.playSoundEffect(
                            AudioManager.FX_KEYPRESS_STANDARD,
                            volume
                        )
                    }
                }

                if(!ringerMode.value) {
                    Tip(stringResource(R.string.typing_settings_keypress_sound_volume_ringer_mode_warning))
                }

                Tip(stringResource(R.string.typing_settings_keypress_sound_volume_vendor_warning))

                SettingSlider(
                    title = stringResource(R.string.typing_settings_keypress_sound_volume),
                    setting = keySoundVolumeSetting,
                    range = 0.0f .. 1.0f,
                    hardRange = 0.0f .. 1.0f,
                    transform = {
                        value.floatValue = it
                        if(it == 0.0f) {
                            -1.0f
                        } else {
                            it
                        }
                    },
                    indicator = {
                        if(it <= 0.0f) {
                            resources.getString(R.string.typing_settings_keypress_sound_volume_default)
                        } else {
                            "${(it * 100.0f).roundToInt()}%"
                        }
                    }
                )
            }
        ),

        userSettingNavigationItem(
            title = R.string.sebtype_settings_action_bar,
            subtitle = R.string.sebtype_settings_action_bar_subtitle,
            style = NavigationItemStyle.Misc,
            navigateTo = "actionEdit"
        ),
    )
)