package dev.sebb.sebtype.settings

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import dev.sebb.sebtype.BuildConfig
import dev.sebb.sebtype.R
import dev.sebb.sebtype.Updates
import dev.sebb.sebtype.data.ChineseData
import dev.sebb.sebtype.data.LearnedWords
import dev.sebb.sebtype.data.Prefs
import kotlin.math.roundToInt

/** A switch for a phone-only option (DataStore) */
@Composable
internal fun PrefSwitch(title: String, subtitle: String? = null, option: Prefs.Option<Boolean>) {
    val context = LocalContext.current
    val on by Prefs.flow(context, option).collectAsState(Prefs[option])
    SwitchItem(title, subtitle, on) { Prefs.set(context, option, it) }
}

/** A switch for one of sebtype.conf's options, which every device shares */
@Composable
internal fun ConfSwitch(title: String, subtitle: String?, section: String, key: String, default: Boolean) {
    val context = LocalContext.current
    SwitchItem(title, subtitle, Conf.get(section, key, default)) { Conf.set(context, section, key, it) }
}

// --- Languages ---

/** The globe order (#41): the languages that are on, in 🌐's order, then those that are off; drag ≡ to reorder. */
@Composable
internal fun GlobeOrder() {
    val context = LocalContext.current
    val on = Conf.languages()
    val rows = on + Conf.LANGUAGES.filter { it !in on }
    val current by rememberUpdatedState(on)
    var dragging by remember { mutableStateOf<String?>(null) }
    var offset by remember { mutableFloatStateOf(0f) }
    val rowHeight = with(LocalDensity.current) { 68.dp.toPx() }

    fun move(language: String, by: Int) {
        val order = current.toMutableList()
        val from = order.indexOf(language)
        val to = (from + by).coerceIn(0, order.size - 1)
        if (from < 0 || from == to) return
        order.add(to, order.removeAt(from))
        Conf.setLanguages(context, order)
    }

    Card {
        rows.forEach { language ->
            key(language) {
                val isOn = language in on
                val dragged = dragging == language
                Item(
                    title = when (language) {
                        "zh" -> stringResource(R.string.sebtype_settings_globe_zh)
                        "ja" -> stringResource(R.string.sebtype_settings_globe_ja)
                        else -> "English"
                    },
                    subtitle = when (language) {
                        "zh" -> stringResource(R.string.sebtype_settings_zh_engine)
                        "ja" -> stringResource(R.string.sebtype_settings_ja_engine)
                        else -> null
                    },
                    modifier = Modifier.zIndex(if (dragged) 1f else 0f)
                        .offset { IntOffset(0, if (dragged) offset.roundToInt() else 0) },
                    icon = {
                        Icon(
                            Icons.Filled.Menu, stringResource(R.string.sebtype_settings_drag), tint = Muted,
                            modifier = if (isOn) Modifier.pointerInput(language) {
                                detectDragGestures(
                                    onDragStart = { dragging = language; offset = 0f },
                                    onDragEnd = { move(language, (offset / rowHeight).roundToInt()); dragging = null },
                                    onDragCancel = { dragging = null },
                                    onDrag = { change, amount -> change.consume(); offset += amount.y },
                                )
                            } else Modifier.alpha(0.3f),
                        )
                    },
                ) {
                    androidx.compose.material3.Switch(
                        checked = isOn,
                        enabled = !(isOn && on.size == 1), // one language always stays on
                        onCheckedChange = { turnOn -> Conf.setLanguages(context, if (turnOn) on + language else on - language) },
                    )
                }
            }
        }
    }
}

@Composable
fun LanguagesScreen(nav: Nav) = Screen(stringResource(R.string.sebtype_settings_languages), nav::back) {
    val context = LocalContext.current
    SectionTag(stringResource(R.string.sebtype_settings_globe_order))
    Tip(stringResource(R.string.sebtype_settings_globe_order_tip))
    GlobeOrder()
    Card {
        PrefSwitch(stringResource(R.string.sebtype_settings_quick_switch), stringResource(R.string.sebtype_settings_quick_switch_subtitle), Prefs.QUICK_SWITCH)
    }

    SectionTag("English")
    Card {
        PrefSwitch(stringResource(R.string.sebtype_settings_autocorrect), option = Prefs.AUTOCORRECT)
        PrefSwitch(stringResource(R.string.sebtype_settings_capitalise), option = Prefs.CAPITALISE)
        PrefSwitch(stringResource(R.string.sebtype_settings_double_space), option = Prefs.DOUBLE_SPACE_PERIOD)
        PrefSwitch(stringResource(R.string.sebtype_settings_emoji_suggestions), option = Prefs.EMOJI_SUGGESTIONS)
        NavItem(stringResource(R.string.sebtype_settings_my_words), stringResource(R.string.sebtype_settings_my_words_en)) { nav.go("words/en") }
    }

    SectionTag("中文")
    Card {
        val fuzzy by Prefs.flow(context, Prefs.FUZZY).collectAsState(Prefs[Prefs.FUZZY])
        NavItem(stringResource(R.string.settings_fuzzy),
            ChineseData.Fuzzy.of(fuzzy).joinToString(", ") { it.label.replace(" ", "") }
                .ifEmpty { stringResource(R.string.sebtype_settings_off) }) { nav.go("fuzzy") }
        ConfSwitch(stringResource(R.string.sebtype_settings_zh_emoji), stringResource(R.string.sebtype_settings_zh_emoji_subtitle),
            "Chinese", "Emoji", true)
        ConfSwitch(stringResource(R.string.sebtype_settings_zh_punctuation), stringResource(R.string.sebtype_settings_zh_punctuation_subtitle),
            "Chinese", "FullWidthPunctuation", true)
        NavItem(stringResource(R.string.sebtype_settings_my_words), stringResource(R.string.sebtype_settings_my_words_zh)) { nav.go("words/zh") }
    }

    SectionTag("日本語")
    Card {
        ConfSwitch(stringResource(R.string.settings_half_width_space), stringResource(R.string.settings_half_width_space_subtitle),
            "Japanese", "HalfWidthSpace", false)
        NavItem(stringResource(R.string.sebtype_settings_my_words), stringResource(R.string.sebtype_settings_my_words_ja)) { nav.go("words/ja") }
    }
}

/** Fuzzy pinyin's checklist: each pair of sounds that may be typed for one another. */
@Composable
fun FuzzyScreen(nav: Nav) = Screen(stringResource(R.string.settings_fuzzy), nav::back) {
    val context = LocalContext.current
    val value by Prefs.flow(context, Prefs.FUZZY).collectAsState(Prefs[Prefs.FUZZY])
    val on = ChineseData.Fuzzy.of(value)
    Card {
        ChineseData.Fuzzy.entries.forEach { mode ->
            SwitchItem(mode.label, null, mode in on) { enabled ->
                val fuzzy = if (enabled) on + mode else on - mode
                Prefs.set(context, Prefs.FUZZY, ChineseData.Fuzzy.names(fuzzy))
                ChineseData.setFuzzy(context, fuzzy)
            }
        }
    }
}

// --- Keyboard ---

@Composable
fun KeyboardScreen(nav: Nav) = Screen(stringResource(R.string.settings_keyboard), nav::back) {
    val context = LocalContext.current
    Card {
        PrefSwitch(stringResource(R.string.settings_number_row), stringResource(R.string.settings_number_row_subtitle), Prefs.NUMBER_ROW)
        SizeAndPosition()
        PrefSwitch(stringResource(R.string.sebtype_settings_hints), stringResource(R.string.sebtype_settings_hints_subtitle), Prefs.SHOW_HINTS)
        val ms by Prefs.flow(context, Prefs.LONG_PRESS_MS).collectAsState(Prefs[Prefs.LONG_PRESS_MS])
        // Today's slider: a heading, the explanation, then the value and a slider in 25 ms steps
        Column(Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.settings_long_press), style = HeadingText, color = Ink, modifier = Modifier.padding(16.dp))
            Text(stringResource(R.string.settings_long_press_subtitle), style = BodyText.copy(fontWeight = FontWeight.Medium), color = Ink,
                modifier = Modifier.padding(horizontal = 12.dp))
            Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.settings_long_press_ms, ms), style = SubtitleText, color = Ink, modifier = Modifier.weight(0.33f))
                Slider(
                    value = ms.toFloat(), valueRange = 100f..700f, steps = 23, modifier = Modifier.weight(1f),
                    onValueChange = { Prefs.set(context, Prefs.LONG_PRESS_MS, ((it / 25).roundToInt() * 25)) },
                )
            }
        }
    }
    SectionTag(stringResource(R.string.sebtype_settings_feedback))
    Card {
        PrefSwitch(stringResource(R.string.settings_key_popup), option = Prefs.KEY_POPUP)
        PrefSwitch(stringResource(R.string.settings_vibrate), option = Prefs.VIBRATE)
        val strength by Prefs.flow(context, Prefs.VIBRATE_STRENGTH).collectAsState(Prefs[Prefs.VIBRATE_STRENGTH])
        Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp)) {
            Text(stringResource(R.string.sebtype_settings_vibrate_strength), fontSize = 18.sp, fontWeight = FontWeight.Medium, color = Ink)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("$strength %", fontSize = 13.sp, color = Ink, modifier = Modifier.width(72.dp))
                Slider(
                    value = strength.toFloat(), valueRange = 10f..100f, steps = 17,
                    onValueChange = { Prefs.set(context, Prefs.VIBRATE_STRENGTH, ((it / 5).roundToInt() * 5)) },
                )
            }
        }
        PrefSwitch(stringResource(R.string.settings_sound), option = Prefs.SOUND)
    }
}

/**
 * Size and position: a field under the row brings the keyboard up in its Keyboard Modes, where the modes
 * and Resize Keyboard are (#257).
 */
@Composable
private fun SizeAndPosition() {
    val context = LocalContext.current
    var open by remember { mutableStateOf(false) }
    NavItem(stringResource(R.string.sebtype_settings_size), stringResource(R.string.sebtype_settings_size_subtitle)) {
        context.getSharedPreferences("keyboard", android.content.Context.MODE_PRIVATE).edit().putBoolean("open_modes", true).apply()
        open = true
    }
    if (open) {
        val focus = remember { androidx.compose.ui.focus.FocusRequester() }
        var text by remember { mutableStateOf("") }
        androidx.compose.material3.OutlinedTextField(text, { text = it },
            Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp).focusRequester(focus),
            placeholder = { Text(stringResource(R.string.sebtype_settings_size_try)) })
        LaunchedEffect(Unit) { focus.requestFocus() }
    }
}

// --- Privacy ---

@Composable
fun PrivacyScreen(nav: Nav) = Screen(stringResource(R.string.sebtype_settings_privacy), nav::back) {
    val context = LocalContext.current
    val keyboard = remember { context.getSharedPreferences("keyboard", android.content.Context.MODE_PRIVATE) }
    var incognito by remember { mutableStateOf(keyboard.getBoolean("incognito", false)) }
    var forgetting by remember { mutableStateOf(false) }
    Card {
        ConfSwitch(stringResource(R.string.sebtype_settings_learn), stringResource(R.string.sebtype_settings_learn_subtitle), "Learning", "On", true)
        // The same switch as the menu's incognito button (#31).
        SwitchItem(stringResource(R.string.sebtype_incognito), stringResource(R.string.sebtype_incognito_subtitle), incognito) {
            keyboard.edit().putBoolean("incognito", it).apply()
            incognito = it
        }
    }
    SectionTag(stringResource(R.string.sebtype_settings_clipboard))
    Card {
        PrefSwitch(stringResource(R.string.sebtype_settings_clipboard_keep_history), option = Prefs.CLIPBOARD_HISTORY)
        NavItem(stringResource(R.string.sebtype_settings_forget), stringResource(R.string.sebtype_settings_forget_subtitle)) { forgetting = true }
    }
    if (forgetting) ForgetDialog { forgetting = false }
}

@Composable
private fun ForgetDialog(close: () -> Unit) {
    val context = LocalContext.current
    var language by remember { mutableStateOf("en") }
    AlertDialog(
        onDismissRequest = close,
        title = { Text(stringResource(R.string.sebtype_settings_forget)) },
        text = {
            Column {
                Text(stringResource(R.string.sebtype_settings_forget_confirm))
                listOf("en" to "English", "zh" to "中文", "ja" to "日本語").forEach { (code, name) ->
                    Row(Modifier.fillMaxWidth().selectable(language == code) { language = code }.padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically) {
                        RadioButton(selected = language == code, onClick = null)
                        Text(name, fontSize = 17.sp, modifier = Modifier.padding(start = 16.dp))
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                val app = context.applicationContext
                LearnedWords.forget(app, language) { Toast.makeText(app, R.string.sebtype_settings_forgotten, Toast.LENGTH_SHORT).show() }
                close()
            }) { Text(stringResource(R.string.sebtype_settings_forget_button)) }
        },
        dismissButton = { TextButton(onClick = close) { Text(stringResource(android.R.string.cancel)) } },
    )
}

// --- About ---

@Composable
fun AboutScreen(nav: Nav) = Screen(stringResource(R.string.sebtype_settings_about), nav::back) {
    val context = LocalContext.current
    Card {
        Item(stringResource(R.string.sebtype_settings_version), BuildConfig.VERSION_NAME)
        NavItem(stringResource(R.string.settings_tips), stringResource(R.string.settings_tips_subtitle)) { nav.go("tips") }
        NavItem(stringResource(R.string.sebtype_settings_help), stringResource(R.string.sebtype_settings_help_subtitle)) {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/S-Sebb/SebType/issues")))
        }
        NavItem(stringResource(R.string.sebtype_settings_credits), stringResource(R.string.settings_credits_subtitle)) { nav.go("credits") }
    }
    if (remember { Updates.enabled(context) }) {
        SectionTag(stringResource(R.string.update_channel))
        Card {
            UpdateItem()
            ReleaseNotes()
            AutoUpdateSwitch()
        }
    }
}

/** Formatted GitHub release notes for the pending update (#428); shows nothing if none are available. */
@Composable
private fun ReleaseNotes() {
    val release by Updates.available.collectAsState()
    val lines = remember(release?.notes) { Updates.parseNotes(release?.notes) }
    if (lines.isEmpty()) return
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .heightIn(max = 280.dp)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        lines.forEachIndexed { index, line ->
            when (line) {
                is Updates.NoteLine.Heading -> Text(
                    text = line.text,
                    style = SubtitleText.copy(fontWeight = FontWeight.Bold),
                    color = Ink,
                    modifier = if (index == 0) Modifier else Modifier.padding(top = 6.dp),
                )
                is Updates.NoteLine.Bullet -> Row(Modifier.fillMaxWidth()) {
                    Text("•", style = SubtitleText, color = Muted, modifier = Modifier.padding(end = 6.dp))
                    Text(noteSpans(line.spans), style = SubtitleText, color = Ink)
                }
                is Updates.NoteLine.Text -> Text(noteSpans(line.spans), style = SubtitleText, color = Ink)
            }
        }
    }
}

private fun noteSpans(spans: List<Updates.NoteSpan>) = buildAnnotatedString {
    for (span in spans) {
        if (span.bold) withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(span.text) }
        else append(span.text)
    }
}

/** The update (#422): a newer release to install, or the check for one */
@Composable
fun UpdateItem(icon: (@Composable () -> Unit)? = null) {
    val context = LocalContext.current
    val release by Updates.available.collectAsState()
    val status by Updates.status.collectAsState()
    val found = release
    if (found != null) {
        val subtitle = when (val s = status) {
            is Updates.Status.Downloading -> stringResource(R.string.update_downloading, s.percent)
            Updates.Status.NeedsPermission -> stringResource(R.string.update_allow)
            Updates.Status.Installing -> stringResource(R.string.update_installing)
            is Updates.Status.Failed -> stringResource(s.text, s.detail)
            else -> stringResource(R.string.update_tap)
        }
        NavItem(stringResource(R.string.update_available, found.version), subtitle, icon, arrow = false) {
            Updates.install(context as Activity)
        }
    } else {
        val subtitle = stringResource(when (status) {
            Updates.Status.Checking -> R.string.update_checking
            Updates.Status.UpToDate -> R.string.update_up_to_date
            Updates.Status.CheckFailed -> R.string.update_check_failed
            else -> R.string.update_check_subtitle
        })
        NavItem(stringResource(R.string.update_check), subtitle, icon, arrow = false) { Updates.checkNow(context) }
    }
}

/** The daily check's switch; Android 13+ asks to let it notify when someone first meets it or turns it on. */
@Composable
private fun AutoUpdateSwitch() {
    val context = LocalContext.current
    val on by Prefs.flow(context, Prefs.UPDATE_CHECK).collectAsState(Prefs[Prefs.UPDATE_CHECK])
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {}
    fun askToNotify() {
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) ask.launch(Manifest.permission.POST_NOTIFICATIONS)
    }
    LaunchedEffect(Unit) { if (Prefs[Prefs.UPDATE_CHECK] && Updates.firstMet(context)) askToNotify() }
    SwitchItem(stringResource(R.string.update_auto), stringResource(R.string.update_auto_subtitle), on) {
        Prefs.set(context, Prefs.UPDATE_CHECK, it)
        if (it) askToNotify()
    }
}

/** One line of assets/credits.tsv: a component the app ships, its licence, where it comes from and its licence texts. */
private data class Component(val name: String, val licence: String, val url: String, val texts: List<String>)

private fun credits(context: Context) = context.assets.open("credits.tsv").bufferedReader().readLines()
    .filter { it.isNotBlank() && !it.startsWith("#") }
    .map { line -> line.split('\t').let { Component(it[0], it[1], it[2], it.getOrElse(3) { "" }.split(',').filter(String::isNotEmpty)) } }

/** The licences and credits: one list of what the app is built from (assets/credits.tsv, #254); a row opens its licence texts. */
@Composable
fun CreditsScreen(nav: Nav) = Screen(stringResource(R.string.sebtype_settings_credits), nav::back) {
    val context = LocalContext.current
    val components = remember { credits(context) }
    Text(stringResource(R.string.settings_credits_intro), style = BodyText, color = Ink,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 12.dp))
    SectionTag(stringResource(R.string.settings_credits_tag))
    Card {
        components.forEachIndexed { i, c ->
            Item(c.name, "${c.licence} · ${c.url.removePrefix("https://")}", Modifier.clickable {
                if (c.texts.isEmpty()) context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(c.url)))
                else nav.go("licence/$i")
            })
        }
    }
}

/** One component's licence texts as the app ships them, under a link to its source. */
@Composable
fun LicenceScreen(nav: Nav, index: Int) {
    val context = LocalContext.current
    val c = remember { credits(context)[index] }
    Screen(c.name, nav::back) {
        Card {
            Item(c.url.removePrefix("https://"), c.licence,
                Modifier.clickable { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(c.url))) })
        }
        c.texts.forEach { path ->
            SectionTag(path.substringAfterLast('/'))
            Text(remember(path) { context.assets.open(path).bufferedReader().readText() },
                style = SubtitleText.copy(fontFamily = FontFamily.Monospace), color = Ink,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 16.dp))
        }
    }
}
