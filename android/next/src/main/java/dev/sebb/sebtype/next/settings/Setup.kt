package dev.sebb.sebtype.next.settings

import android.content.Intent
import android.graphics.BitmapFactory
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.systemBars
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.TextUnit
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
 *
 * Today's layout: the launcher icon's pig fills the top three quarters of the height the rest leaves (step 3,
 * with the tips, less than half), and the rest of that height stays empty under the button. When the screen
 * is too short for that (landscape, large text) the pig keeps a small size and the page scrolls, so the
 * button can always be reached.
 */
@Composable
fun Setup(state: Pair<Boolean, Boolean>, done: () -> Unit) = BoxWithConstraints(
    Modifier.fillMaxSize().cloth().windowInsetsPadding(WindowInsets.systemBars),
) {
    val context = LocalContext.current
    val step = if (!state.first) 1 else if (!state.second) 2 else 3
    val viewport = constraints.maxHeight
    val minPig = with(LocalDensity.current) { 96.dp.roundToPx() }
    // Its bitmap is loaded unscaled and scaled without smoothing so the pixel art's edges stay crisp.
    val pig = remember {
        BitmapFactory.decodeResource(context.resources, R.mipmap.ic_launcher_pig, BitmapFactory.Options().apply { inScaled = false })
            .asImageBitmap()
    }
    Layout(
        content = {
            Image(pig, null, filterQuality = FilterQuality.None)
            Column(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(start = 32.dp, top = 32.dp, end = 32.dp)) {
                    Column(Modifier.padding(16.dp)) {
                        Text(stringResource(R.string.setup_step, step), fontSize = 14.sp, lineHeight = 20.sp, color = Ink)
                        LinearProgressIndicator({ step / 3f }, Modifier.fillMaxWidth(), color = Berry, gapSize = 0.dp, drawStopIndicator = {})
                    }
                    // Step 3's lead-in without letter spacing, as the tips below it, so it keeps to one line
                    Text(stringResource(listOf(R.string.setup_enable_text, R.string.setup_choose_text, R.string.setup_tips_text)[step - 1]),
                        Modifier.fillMaxWidth(), color = Ink, textAlign = TextAlign.Center,
                        letterSpacing = if (step == 3) 0.sp else TextUnit.Unspecified)
                }
                if (step == 3) {
                    Spacer(Modifier.height(12.dp))
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
                    Modifier.fillMaxWidth().padding(start = 48.dp, end = 48.dp, top = if (step == 3) 12.dp else 16.dp, bottom = 48.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = Berry, contentColor = Color.White),
                ) { Text(stringResource(listOf(R.string.setup_enable, R.string.setup_choose, R.string.setup_done)[step - 1])) }
            }
        },
        modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),
    ) { (image, group), c ->
        val g = group.measure(c.copy(minHeight = 0))
        val free = (viewport - g.height).coerceAtLeast(0)
        val pigHeight = maxOf(minPig, (free * if (step == 3) 0.45f else 0.75f).toInt())
        val p = image.measure(Constraints.fixed(c.maxWidth, pigHeight))
        layout(c.maxWidth, maxOf(viewport, pigHeight + g.height)) {
            p.place(0, 0)
            g.place(0, pigHeight)
        }
    }
}
