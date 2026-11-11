package org.futo.inputmethod.latin.uix.settings.pages

import android.content.Intent
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment.Companion.CenterVertically
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.graphics.drawable.toBitmap
import androidx.navigation.NavHostController
import androidx.navigation.compose.rememberNavController
import org.futo.inputmethod.latin.R
import org.futo.inputmethod.latin.settings.Settings
import org.futo.inputmethod.latin.uix.TextEditPopupActivity
import org.futo.inputmethod.latin.uix.actions.clipboard.ClipboardHistoryEnabled
import org.futo.inputmethod.latin.uix.settings.SettingsCard
import org.futo.inputmethod.latin.uix.settings.BottomSpacer
import org.futo.inputmethod.latin.uix.settings.NavigationItem
import org.futo.inputmethod.latin.uix.settings.NavigationItemStyle
import org.futo.inputmethod.latin.uix.settings.ScrollableList
import org.futo.inputmethod.latin.uix.settings.useDataStoreValue
import org.futo.inputmethod.latin.uix.settings.useSharedPrefsBool
import org.futo.inputmethod.latin.uix.theme.Typography

// SebType's home (#41): five groups (Theme went with #111), each line showing its current state, at most two taps from any
// option. FUTO's payment reminder still appears here when it is due; the payment screen is in About.
@Composable
private fun HomeGroups(navController: NavHostController) {
    val context = LocalContext.current
    val subtypes = useSubtypesInOrder()
    val autocorrect = useSharedPrefsBool(Settings.PREF_AUTO_CORRECTION, true).value
    val learning = useSharedPrefsBool(Settings.PREF_KEY_USE_PERSONALIZED_DICTS, true).value
    val clipboard = useDataStoreValue(ClipboardHistoryEnabled)

    SettingsCard {
        NavigationItem(
            title = stringResource(R.string.sebtype_settings_languages),
            subtitle = globeOrderSummary(subtypes) + " · " + stringResource(
                if(autocorrect) R.string.sebtype_settings_autocorrect_on else R.string.sebtype_settings_autocorrect_off),
            style = NavigationItemStyle.HomePrimary,
            icon = painterResource(R.drawable.globe),
            navigate = { navController.navigate("languages") }
        )
        NavigationItem(
            title = stringResource(R.string.keyboard_settings_title),
            subtitle = stringResource(R.string.sebtype_settings_keyboard_subtitle),
            style = NavigationItemStyle.HomeSecondary,
            icon = painterResource(R.drawable.keyboard),
            navigate = { navController.navigate("keyboard") }
        )
    }
    SettingsCard {
        NavigationItem(
            title = stringResource(R.string.sebtype_settings_privacy),
            subtitle = stringResource(if(learning) R.string.sebtype_settings_learning_on else R.string.sebtype_settings_learning_off) +
                " · " + stringResource(if(clipboard) R.string.sebtype_settings_clipboard_on else R.string.sebtype_settings_clipboard_off),
            style = NavigationItemStyle.HomePrimary,
            icon = rememberVectorPainter(Icons.Default.Lock),
            navigate = { navController.navigate("privacy") }
        )
        NavigationItem(
            title = stringResource(R.string.sebtype_settings_backup),
            subtitle = stringResource(R.string.sebtype_settings_backup_subtitle),
            style = NavigationItemStyle.HomeSecondary,
            icon = rememberVectorPainter(Icons.Default.Refresh),
            navigate = { navController.navigate("backup") }
        )
    }
    SettingsCard {
        NavigationItem(
            title = stringResource(R.string.sebtype_settings_about),
            subtitle = stringResource(R.string.sebtype_settings_about_subtitle),
            style = NavigationItemStyle.HomeTertiary,
            icon = rememberVectorPainter(Icons.Default.Info),
            navigate = { navController.navigate("about") }
        )
    }
}

@Composable
fun HomeScreen(navController: NavHostController = rememberNavController()) {
    val context = LocalContext.current
    val icon = remember { context.packageManager.getApplicationIcon(context.packageName).toBitmap().asImageBitmap() }

    ScrollableList {
        Spacer(modifier = Modifier.height(24.dp))
        Row(Modifier.padding(16.dp), verticalAlignment = CenterVertically) {
            Image(icon, contentDescription = null, modifier = Modifier.size(56.dp))
            Spacer(Modifier.width(12.dp))
            Column {
                Text(stringResource(R.string.sebtype_app_name), style = Typography.Heading.Medium)
                Text(stringResource(R.string.sebtype_settings_subtitle), style = Typography.Small)
            }
        }

        SettingsCard {
            TextButton(onClick = {
                val intent = Intent()
                intent.setClass(context, TextEditPopupActivity::class.java)
                intent.setFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                )
                context.startActivity(intent)
            }, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(R.string.settings_try_typing_here), color = MaterialTheme.colorScheme.onBackground.copy(alpha = 0.7f), modifier = Modifier.fillMaxWidth())
            }
        }

        ConditionalUnpaidNoticeWithNav(navController)

        HomeGroups(navController)
        BottomSpacer()
    }
}