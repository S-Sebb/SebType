package dev.sebb.sebtype.next.settings

import android.content.Context
import android.database.ContentObserver
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.inputmethod.InputMethodManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.runtime.toMutableStateList
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.graphics.asImageBitmap
import androidx.core.graphics.drawable.toBitmap
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.sebb.sebtype.next.Engines
import dev.sebb.sebtype.next.R
import dev.sebb.sebtype.next.data.Prefs
import kotlinx.coroutines.flow.map

/**
 * SebType's settings (#41, #254): a home screen of five groups (Languages, Keyboard, Privacy, Sync & backup,
 * About) and their screens, or the setup wizard while SebType isn't the keyboard in use.
 */
class SettingsActivity : ComponentActivity() {
    // Goes up when SebType is turned on or chosen, however that happens (Android's keyboard settings, the
    // picker, another app), so the wizard goes on or ends.
    private val changes = mutableIntStateOf(0)
    private val keyboards = object : ContentObserver(Handler(Looper.getMainLooper())) {
        override fun onChange(selfChange: Boolean) { changes.intValue++ }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        picnicEdgeToEdge()
        super.onCreate(savedInstanceState)
        Engines.configure(this)
        for (name in listOf(Settings.Secure.DEFAULT_INPUT_METHOD, Settings.Secure.ENABLED_INPUT_METHODS)) {
            contentResolver.registerContentObserver(Settings.Secure.getUriFor(name), false, keyboards)
        }
        setContent { PicnicTheme { App(changes.intValue) } }
    }

    override fun onResume() {
        super.onResume()
        changes.intValue++
    }

    override fun onDestroy() {
        contentResolver.unregisterContentObserver(keyboards)
        super.onDestroy()
    }
}

/** Whether SebType is on in Android's keyboards, and whether it is the one in use */
fun keyboardState(context: Context): Pair<Boolean, Boolean> {
    val imm = context.getSystemService(InputMethodManager::class.java)
    val enabled = imm.enabledInputMethodList.any { it.packageName == context.packageName }
    val current = Settings.Secure.getString(context.contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
        ?.substringBefore('/') == context.packageName
    return enabled to current
}

/** sebtype.conf's options for the screens; [version] goes up on each change, so they read them again. */
object Conf {
    val version = mutableIntStateOf(0)

    fun get(section: String, key: String, default: Boolean): Boolean {
        version.intValue
        return Engines.setting(section, key) ?: default
    }

    fun set(context: Context, section: String, key: String, on: Boolean) =
        Engines.changeSettings(context, "[$section]\n$key=$on\n") { version.intValue++ }

    /** The languages that are on, in 🌐's order: "en", "zh", "ja". */
    fun languages(): List<String> {
        version.intValue
        return Engines.languages().map { LANGUAGES[it] }
    }

    fun setLanguages(context: Context, order: List<String>) =
        Engines.changeSettings(context, "[Languages]\nOrder=${order.joinToString(",")}\n") { version.intValue++ }

    val LANGUAGES = listOf("en", "zh", "ja")
}

@Composable
private fun App(changes: Int) {
    val context = LocalContext.current
    val stack: SnapshotStateList<String> = rememberSaveable(
        saver = androidx.compose.runtime.saveable.listSaver(save = { it.toList() }, restore = { it.toMutableStateList() }),
    ) { mutableListOf<String>().toMutableStateList() }
    val state = remember(changes) { keyboardState(context) }
    val nav = Nav(stack)
    // Read from the file, not Prefs.current, which a new process may not have loaded yet: a tips page
    // left open must not pass for a first start.
    val setup = remember { Prefs.flow(context, Prefs.SETUP).map<Int, Int?> { it } }.collectAsState(null).value ?: return
    if (setup == Prefs.SETUP_UNSEEN) LaunchedEffect(Unit) {
        // SebType already on: someone who set it up before the tips existed, or without this app
        Prefs.set(context, Prefs.SETUP, if (state.first) Prefs.SETUP_DONE else Prefs.SETUP_TIPS_DUE)
    }
    if (stack.isEmpty() && !(state.first && state.second && setup != Prefs.SETUP_TIPS_DUE)) {
        return Setup(state) { Prefs.set(context, Prefs.SETUP, Prefs.SETUP_DONE) }
    }
    BackHandler(stack.isNotEmpty()) { nav.back() }
    when (stack.lastOrNull()) {
        null -> Home(nav)
        "languages" -> LanguagesScreen(nav)
        "fuzzy" -> FuzzyScreen(nav)
        "words/en" -> EnglishWordsScreen(nav)
        "words/zh" -> ChineseWordsScreen(nav)
        "words/ja" -> JapaneseWordsScreen(nav)
        "keyboard" -> KeyboardScreen(nav)
        "privacy" -> PrivacyScreen(nav)
        "backup" -> BackupScreen(nav)
        "about" -> AboutScreen(nav)
        "tips" -> TipsScreen(nav)
        "credits" -> CreditsScreen(nav)
    }
}

class Nav(private val stack: SnapshotStateList<String>) {
    fun go(screen: String) = stack.add(screen)
    fun back() = stack.removeAt(stack.lastIndex)
}

@Composable
private fun Home(nav: Nav) {
    val autocorrect by Prefs.flow(LocalContext.current, Prefs.AUTOCORRECT).collectAsState(Prefs[Prefs.AUTOCORRECT])
    val clipboard by Prefs.flow(LocalContext.current, Prefs.CLIPBOARD_HISTORY).collectAsState(Prefs[Prefs.CLIPBOARD_HISTORY])
    val learning = Conf.get("Learning", "On", true)
    val short = mapOf("en" to "EN", "zh" to "中", "ja" to "日")
    Screen(null, null) {
        // The launcher icon as Android draws it: the pig on its pink circle
        val context = LocalContext.current
        val icon = remember { context.packageManager.getApplicationIcon(context.packageName).toBitmap().asImageBitmap() }
        Row(Modifier.padding(start = 16.dp, top = 40.dp, end = 16.dp, bottom = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            Image(icon, null, Modifier.size(56.dp))
            Column(Modifier.padding(start = 12.dp)) {
                Text("SebType", style = HeadingText, color = Ink)
                Text(stringResource(R.string.sebtype_settings_subtitle), style = SubtitleText.copy(lineHeight = 14.sp), color = Ink)
            }
        }
        TryTyping()
        Card {
            NavItem(stringResource(R.string.sebtype_settings_languages),
                Conf.languages().joinToString(" → ") { short.getValue(it) } + " · " +
                    stringResource(if (autocorrect) R.string.sebtype_settings_autocorrect_on else R.string.sebtype_settings_autocorrect_off),
                arrow = false, icon = { Badge(false) { Globe() } }) { nav.go("languages") }
            NavItem(stringResource(R.string.settings_keyboard), stringResource(R.string.settings_keyboard_subtitle),
                arrow = false, icon = { Badge(true) { KeyboardIcon() } }) { nav.go("keyboard") }
        }
        Card {
            NavItem(stringResource(R.string.sebtype_settings_privacy),
                stringResource(if (learning) R.string.sebtype_settings_learning_on else R.string.sebtype_settings_learning_off) + " · " +
                    stringResource(if (clipboard) R.string.sebtype_settings_clipboard_on else R.string.sebtype_settings_clipboard_off),
                arrow = false, icon = { Badge(false) { Icon(Icons.Filled.Lock, null, tint = Ink) } }) { nav.go("privacy") }
            NavItem(stringResource(R.string.sebtype_settings_backup), stringResource(R.string.sebtype_settings_backup_subtitle),
                arrow = false, icon = { Badge(true) { Icon(Icons.Filled.Refresh, null, tint = Color.White) } }) { nav.go("backup") }
        }
        Card {
            NavItem(stringResource(R.string.sebtype_settings_about), stringResource(R.string.settings_about_subtitle),
                arrow = false, icon = { Badge(false) { Icon(Icons.Filled.Info, null, tint = Ink) } }) { nav.go("about") }
        }
    }
}

/** A field to try the keyboard in, framed like a card */
@Composable
private fun TryTyping() {
    var text by rememberSaveable { mutableStateOf("") }
    val hint = stringResource(R.string.settings_try_typing)
    // Today's text button in a card: a 48dp row, its label in Material's label style at 70% ink
    val style = TextStyle(fontSize = 14.sp, lineHeight = 20.sp, letterSpacing = 0.1.sp, fontWeight = FontWeight.Medium,
        color = Ink.copy(alpha = 0.7f))
    BasicTextField(
        text, { text = it },
        textStyle = style.copy(color = Ink),
        cursorBrush = SolidColor(Ink),
        modifier = Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, bottom = 12.dp).framed(),
        decorationBox = { inner ->
            Box(Modifier.heightIn(min = 48.dp).padding(horizontal = 12.dp), contentAlignment = Alignment.CenterStart) {
                if (text.isEmpty()) Text(hint, style = style)
                inner()
            }
        },
    )
}
