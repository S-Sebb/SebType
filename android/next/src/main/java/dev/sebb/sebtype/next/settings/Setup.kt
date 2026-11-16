package dev.sebb.sebtype.next.settings

import android.content.Intent
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.sebb.sebtype.next.R

/**
 * The setup wizard (#53), as today's app shows it: the pig, the step, what to do and one button. Step 1 turns
 * SebType on in Android's keyboards, step 2 chooses it; each opens Android's own screen, and the settings open
 * once both are done. [state] is (on, chosen).
 */
@Composable
fun Setup(state: Pair<Boolean, Boolean>) = Column(
    Modifier.fillMaxSize().cloth().padding(horizontal = 32.dp),
    verticalArrangement = Arrangement.Center,
    horizontalAlignment = Alignment.CenterHorizontally,
) {
    val context = LocalContext.current
    val step = if (state.first) 2 else 1
    // The launcher icon's pig, a one-colour silhouette with room around it, in ink as today's.
    Image(painterResource(R.drawable.ic_launcher_foreground), null, Modifier.size(320.dp), colorFilter = ColorFilter.tint(Ink))
    Row(Modifier.fillMaxWidth().padding(bottom = 16.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(stringResource(R.string.setup_step, step), fontSize = 12.sp, color = Ink)
        LinearProgressIndicator({ step / 2f }, Modifier.weight(1f).padding(start = 8.dp), color = Berry, trackColor = Line,
            drawStopIndicator = {})
    }
    Text(stringResource(if (step == 1) R.string.setup_enable_text else R.string.setup_choose_text),
        color = Ink, fontSize = 15.sp, textAlign = TextAlign.Center)
    Button(
        onClick = {
            if (step == 1) context.startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            else context.getSystemService(InputMethodManager::class.java).showInputMethodPicker()
        },
        Modifier.fillMaxWidth().padding(top = 24.dp),
        shape = RoundedCornerShape(50),
        colors = ButtonDefaults.buttonColors(containerColor = Berry, contentColor = Color.White),
    ) { Text(stringResource(if (step == 1) R.string.setup_enable else R.string.setup_choose)) }
}
