package org.futo.inputmethod.latin.uix.settings.pages

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.widget.Toast
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import kotlinx.coroutines.runBlocking
import org.futo.inputmethod.latin.BuildConfig
import org.futo.inputmethod.latin.R
import org.futo.inputmethod.latin.uix.getSetting
import org.futo.inputmethod.latin.uix.setSetting
import org.futo.inputmethod.latin.uix.settings.NavigationItem
import org.futo.inputmethod.latin.uix.settings.NavigationItemStyle
import org.futo.inputmethod.latin.uix.settings.UserSetting
import org.futo.inputmethod.latin.uix.settings.UserSettingsMenu
import org.futo.inputmethod.latin.uix.settings.useDataStoreValue
import org.futo.inputmethod.latin.uix.settings.userSettingNavigationItem
import org.futo.inputmethod.updates.openURI

internal fun Context.copyToClipboard(text: CharSequence, label: String = "Copied Text") {
    val clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    val clipData = ClipData.newPlainText(label, text)
    clipboardManager.setPrimaryClip(clipData)
}

// SebType: FUTO's Help & Feedback is now About: the version (tapping it eight times turns on developer
// mode, as before), help through SebType's own issues, FUTO's payment and licence screens.
val AboutMenu = UserSettingsMenu(
    title = R.string.sebtype_settings_about,
    navPath = "about", registerNavPath = true,
    settings = listOf(
        UserSetting(
            name = R.string.sebtype_settings_version
        ) {
            val context = LocalContext.current
            val numPresses = remember { mutableIntStateOf(0) }
            var lastToast: MutableState<Toast?> = remember { mutableStateOf(null) }
            NavigationItem(
                title = stringResource(R.string.sebtype_settings_version),
                subtitle = BuildConfig.VERSION_NAME,
                style = NavigationItemStyle.MiscNoArrow,
                navigate = {
                    context.copyToClipboard(BuildConfig.VERSION_NAME)
                    val makeToast: (String) -> Unit = { text ->
                        Toast.makeText(context, text, Toast.LENGTH_SHORT).let {
                            lastToast.value?.cancel()
                            lastToast.value = it
                            it.show()
                        }
                    }
                    if(runBlocking { context.getSetting(IS_DEVELOPER) }) {
                        makeToast("You're already a developer")
                    } else {
                        numPresses.intValue += 1
                        if (numPresses.intValue > 3) {
                            val pressesUntilDeveloper = 8 - numPresses.intValue
                            if (pressesUntilDeveloper <= 0) {
                                makeToast("You're now a developer")
                                runBlocking { context.setSetting(IS_DEVELOPER, true) }
                            } else {
                                makeToast("You are $pressesUntilDeveloper steps until becoming a developer")
                            }
                        }
                    }
                }
            )
        },

        userSettingNavigationItem(
            title = R.string.sebtype_settings_help,
            subtitle = R.string.sebtype_settings_help_subtitle,
            style = NavigationItemStyle.Misc,
            navigate = { nav ->
                nav.context.openURI("https://github.com/S-Sebb/SebType/issues")
            }
        ),
        userSettingNavigationItem(
            title = R.string.sebtype_settings_support_futo,
            subtitle = R.string.sebtype_settings_support_futo_subtitle,
            style = NavigationItemStyle.Misc,
            navigateTo = "payment"
        ),
        userSettingNavigationItem(
            title = R.string.sebtype_settings_credits,
            subtitle = R.string.sebtype_settings_credits_subtitle,
            style = NavigationItemStyle.Misc,
            navigateTo = "credits"
        ),
        userSettingNavigationItem(
            title = R.string.dev_settings_title,
            style = NavigationItemStyle.Misc,
            navigateTo = "developer"
        ).copy(visibilityCheck = { useDataStoreValue(IS_DEVELOPER) }),
    )
)