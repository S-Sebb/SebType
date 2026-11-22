package dev.sebb.sebtype.settings

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
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.graphics.FilterQuality
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.sebb.sebtype.R
import dev.sebb.sebtype.data.Prefs
import dev.sebb.sebtype.sync.SyncAccountStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

const val SETUP_STEPS = 5
internal const val SETUP_COMMON = 3
internal const val SETUP_SYNC = 4
internal const val SETUP_TIPS = 5

/** Which step of the setup wizard to show (1..5). */
internal fun setupStep(enabled: Boolean, chosen: Boolean, commonPassed: Boolean, syncPassed: Boolean): Int = when {
    !enabled -> 1
    !chosen -> 2
    !commonPassed -> SETUP_COMMON
    !syncPassed -> SETUP_SYNC
    else -> SETUP_TIPS
}

/** The common settings step's phone-only switches (#444), as the Keyboard screen shows them, at their defaults until changed. */
internal val SETUP_SWITCHES = listOf(
    Triple(R.string.settings_number_row, R.string.settings_number_row_subtitle, Prefs.NUMBER_ROW),
    Triple(R.string.settings_vibrate, null, Prefs.VIBRATE),
    Triple(R.string.settings_sound, null, Prefs.SOUND),
)

/**
 * The setup wizard (#53), as today's app shows it: the pig, the step, what to do and its buttons. Step 1 turns
 * SebType on in Android's keyboards, step 2 chooses it; each opens Android's own screen. Step 3 (#444) holds the
 * most common settings, the same switches the settings screens show, already at their values. Step 4 (#435)
 * offers optional account sync with the user's own server. Step 5 (#285) shows the tips, and its Done calls [done].
 * [state] is (on, chosen).
 *
 * Today's layout: the launcher icon's pig fills the top three quarters of the height the rest leaves (step 3
 * slightly less; the settings and tips steps, less than half), and the rest of that height stays empty under the
 * button. When the screen is too short for that (landscape, large text) the pig keeps a small size and the
 * page scrolls, so the button can always be reached.
 */
@Composable
fun Setup(state: Pair<Boolean, Boolean>, done: () -> Unit) = BoxWithConstraints(
    Modifier.fillMaxSize().cloth().windowInsetsPadding(WindowInsets.systemBars),
) {
    val context = LocalContext.current
    var commonPassed by rememberSaveable { mutableStateOf(false) }
    var syncPassed by rememberSaveable { mutableStateOf(false) }
    var loginOpen by rememberSaveable { mutableStateOf(false) }
    val account by SyncAccountStore.current.collectAsState()
    LaunchedEffect(Unit) { withContext(Dispatchers.IO) { SyncAccountStore.load(context) } }
    val step = setupStep(state.first, state.second, commonPassed, syncPassed)
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
                        Text(stringResource(R.string.setup_step, step, SETUP_STEPS), fontSize = 14.sp, lineHeight = 20.sp, color = Ink)
                        LinearProgressIndicator({ step / SETUP_STEPS.toFloat() }, Modifier.fillMaxWidth(), color = Berry, gapSize = 0.dp, drawStopIndicator = {})
                    }
                    // The tips' lead-in without letter spacing, as the tips below it, so it keeps to one line
                    Text(stringResource(listOf(R.string.setup_enable_text, R.string.setup_choose_text, R.string.setup_common_text,
                        R.string.setup_sync_text, R.string.setup_tips_text)[step - 1]),
                        Modifier.fillMaxWidth(), color = Ink, textAlign = TextAlign.Center,
                        letterSpacing = if (step == SETUP_TIPS) 0.sp else TextUnit.Unspecified)
                }
                val signedIn = account
                if (step == SETUP_COMMON) {
                    Spacer(Modifier.height(12.dp))
                    GlobeOrder()
                    Card {
                        ConfSwitch(stringResource(R.string.setup_traditional), stringResource(R.string.setup_traditional_subtitle),
                            "Chinese", "Traditional", false)
                        SETUP_SWITCHES.forEach { (title, subtitle, option) ->
                            PrefSwitch(stringResource(title), subtitle?.let { stringResource(it) }, option)
                        }
                    }
                }
                if (step == SETUP_SYNC && signedIn != null) {
                    Spacer(Modifier.height(12.dp))
                    Card {
                        NavItem(stringResource(R.string.setup_sync_signed_in), signedIn.summary()) { loginOpen = true }
                    }
                }
                if (step == SETUP_TIPS) {
                    Spacer(Modifier.height(12.dp))
                    TipsCard()
                }
                val showSkip = step == SETUP_SYNC && signedIn == null
                val primaryLabel = when (step) {
                    1 -> R.string.setup_enable
                    2 -> R.string.setup_choose
                    SETUP_COMMON -> R.string.setup_continue
                    SETUP_SYNC -> if (signedIn == null) R.string.setup_sync_setup else R.string.setup_continue
                    else -> R.string.setup_done
                }
                Button(
                    onClick = {
                        when (step) {
                            1 -> context.startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            2 -> context.getSystemService(InputMethodManager::class.java).showInputMethodPicker()
                            SETUP_COMMON -> commonPassed = true
                            SETUP_SYNC -> if (signedIn == null) loginOpen = true else syncPassed = true
                            else -> done()
                        }
                    },
                    Modifier.fillMaxWidth().padding(
                        start = 48.dp,
                        end = 48.dp,
                        top = if (step == SETUP_COMMON || step == SETUP_TIPS || (step == SETUP_SYNC && signedIn != null)) 12.dp else 16.dp,
                        bottom = if (showSkip) 4.dp else 48.dp,
                    ),
                    colors = ButtonDefaults.buttonColors(containerColor = Berry, contentColor = Color.White),
                ) { Text(stringResource(primaryLabel)) }
                if (showSkip) {
                    TextButton(
                        onClick = { syncPassed = true },
                        Modifier.fillMaxWidth().padding(start = 48.dp, end = 48.dp, top = 4.dp, bottom = 48.dp),
                        colors = ButtonDefaults.textButtonColors(contentColor = Berry),
                    ) { Text(stringResource(R.string.setup_sync_skip)) }
                }
            }
        },
        modifier = Modifier.fillMaxWidth().verticalScroll(rememberScrollState()),
    ) { (image, group), c ->
        val g = group.measure(c.copy(minHeight = 0))
        val free = (viewport - g.height).coerceAtLeast(0)
        val pigShare = when (step) {
            SETUP_COMMON, SETUP_TIPS -> 0.45f
            SETUP_SYNC -> 0.55f
            else -> 0.75f
        }
        val pigHeight = maxOf(minPig, (free * pigShare).toInt())
        val p = image.measure(Constraints.fixed(c.maxWidth, pigHeight))
        layout(c.maxWidth, maxOf(viewport, pigHeight + g.height)) {
            p.place(0, 0)
            g.place(0, pigHeight)
        }
    }
    if (loginOpen) SyncLoginDialog { loginOpen = false }
}
