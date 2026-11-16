package dev.sebb.sebtype.next.settings

import android.content.Intent
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.sebb.sebtype.next.R

/**
 * The setup wizard (#53): turn SebType on in Android's keyboards, then choose it. Each step opens Android's
 * own screen; the settings open once both are done. [state] is (on, chosen).
 */
@Composable
fun Setup(state: Pair<Boolean, Boolean>) = Screen(null, null) {
    val context = LocalContext.current
    val (enabled, chosen) = state
    Row(Modifier.padding(start = 16.dp, top = 24.dp, bottom = 16.dp), verticalAlignment = Alignment.CenterVertically) {
        Image(painterResource(R.mipmap.ic_launcher_pig), null, Modifier.size(64.dp).clip(CircleShape))
        Text(stringResource(R.string.setup_title), fontSize = 22.sp, fontWeight = FontWeight.Medium, color = Ink,
            modifier = Modifier.padding(start = 12.dp))
    }
    Card {
        Step(1, stringResource(R.string.setup_enable), stringResource(R.string.setup_enable_subtitle), done = enabled, active = !enabled) {
            context.startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        Step(2, stringResource(R.string.setup_choose), stringResource(R.string.setup_choose_subtitle), done = chosen, active = enabled && !chosen) {
            context.getSystemService(InputMethodManager::class.java).showInputMethodPicker()
        }
    }
}

@Composable
private fun Step(number: Int, title: String, subtitle: String, done: Boolean, active: Boolean, onClick: () -> Unit) = Item(
    title, subtitle,
    Modifier.alpha(if (active || done) 1f else 0.5f).let { if (active) it.clickable(onClick = onClick) else it },
    icon = {
        Badge(berry = active) {
            if (done) Icon(Icons.Filled.Check, null, tint = Ink)
            else Text("$number", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = if (active) Color.White else Ink)
        }
    },
)
