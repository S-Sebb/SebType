package dev.sebb.sebtype.next.settings

import android.content.Intent
import android.graphics.BitmapFactory
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.runtime.remember
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.sebb.sebtype.next.R

/**
 * The setup wizard (#53), as today's app shows it: the pig, the step, what to do and one button. Step 1 turns
 * SebType on in Android's keyboards, step 2 chooses it; each opens Android's own screen. Step 3 (#285), once
 * both are done, shows the tips, and its Done calls [done]. [state] is (on, chosen).
 */
@Composable
fun Setup(state: Pair<Boolean, Boolean>, done: () -> Unit) = Column(Modifier.fillMaxSize().cloth()) {
    val context = LocalContext.current
    val step = if (!state.first) 1 else if (!state.second) 2 else 3
    // Today's layout: the launcher icon's pig, in its colours, fills the top three quarters (less the group
    // below), and a quarter stays empty under the group. Its bitmap is loaded unscaled and scaled up
    // without smoothing so the pixel art's edges stay crisp.
    val pig = remember {
        BitmapFactory.decodeResource(context.resources, R.mipmap.ic_launcher_pig, BitmapFactory.Options().apply { inScaled = false })
            .asImageBitmap()
    }
    Image(pig, null, Modifier.fillMaxWidth().weight(0.75f), filterQuality = FilterQuality.None)
    Column(Modifier.padding(start = 32.dp, top = 32.dp, end = 32.dp)) {
        Column(Modifier.padding(16.dp)) {
            Text(stringResource(R.string.setup_step, step), fontSize = 14.sp, lineHeight = 20.sp, color = Ink)
            LinearProgressIndicator({ step / 3f }, Modifier.fillMaxWidth(), color = Berry, gapSize = 0.dp, drawStopIndicator = {})
        }
        Text(stringResource(listOf(R.string.setup_enable_text, R.string.setup_choose_text, R.string.setup_tips_text)[step - 1]),
            Modifier.fillMaxWidth(), color = Ink, textAlign = TextAlign.Center)
    }
    if (step == 3) {
        Spacer(Modifier.height(16.dp))
        TipsCard()
    }
    Button(
        onClick = {
            when (step) {
                1 -> context.startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                2 -> context.getSystemService(InputMethodManager::class.java).showInputMethodPicker()
                else -> done()
            }
        },
        Modifier.fillMaxWidth().padding(start = 48.dp, end = 48.dp, top = 16.dp, bottom = 48.dp),
        colors = ButtonDefaults.buttonColors(containerColor = Berry, contentColor = Color.White),
    ) { Text(stringResource(listOf(R.string.setup_enable, R.string.setup_choose, R.string.setup_done)[step - 1])) }
    Spacer(Modifier.weight(0.25f))
}
