package org.futo.inputmethod.latin.uix.settings.pages

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import org.futo.inputmethod.latin.BuildConfig
import org.futo.inputmethod.latin.R
import org.futo.inputmethod.latin.uix.settings.NavigationItem
import org.futo.inputmethod.latin.uix.settings.NavigationItemStyle
import org.futo.inputmethod.latin.uix.settings.UserSetting
import org.futo.inputmethod.latin.uix.settings.UserSettingsMenu
import org.futo.inputmethod.latin.uix.settings.userSettingNavigationItem
import org.futo.inputmethod.updates.openURI

internal fun Context.copyToClipboard(text: CharSequence, label: String = "Copied Text") {
    val clipboardManager = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
    val clipData = ClipData.newPlainText(label, text)
    clipboardManager.setPrimaryClip(clipData)
}

// SebType: FUTO's Help & Feedback is now About: the version (a tap copies it), help through SebType's
// own issues, FUTO's payment and licence screens.
val AboutMenu = UserSettingsMenu(
    title = R.string.sebtype_settings_about,
    navPath = "about", registerNavPath = true,
    settings = listOf(
        UserSetting(
            name = R.string.sebtype_settings_version
        ) {
            val context = LocalContext.current
            NavigationItem(
                title = stringResource(R.string.sebtype_settings_version),
                subtitle = BuildConfig.VERSION_NAME,
                style = NavigationItemStyle.MiscNoArrow,
                navigate = {
                    context.copyToClipboard(BuildConfig.VERSION_NAME)
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
    )
)