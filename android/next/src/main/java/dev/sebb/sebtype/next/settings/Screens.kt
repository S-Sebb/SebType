package dev.sebb.sebtype.next.settings

import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.selection.selectable
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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import dev.sebb.sebtype.next.BuildConfig
import dev.sebb.sebtype.next.R
import dev.sebb.sebtype.next.data.ChineseData
import dev.sebb.sebtype.next.data.LearnedWords
import dev.sebb.sebtype.next.data.Prefs
import kotlin.math.roundToInt

/** A switch for a phone-only option (DataStore) */
@Composable
private fun PrefSwitch(title: String, subtitle: String? = null, option: Prefs.Option<Boolean>) {
    val context = LocalContext.current
    val on by Prefs.flow(context, option).collectAsState(Prefs[option])
    SwitchItem(title, subtitle, on) { Prefs.set(context, option, it) }
}

/** A switch for one of sebtype.conf's options, which every device shares */
@Composable
private fun ConfSwitch(title: String, subtitle: String?, section: String, key: String, default: Boolean) {
    val context = LocalContext.current
    SwitchItem(title, subtitle, Conf.get(section, key, default)) { Conf.set(context, section, key, it) }
}

// --- Languages ---

/** The globe order (#41): the languages that are on, in 🌐's order, then those that are off; drag ≡ to reorder. */
@Composable
private fun GlobeOrder() {
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
            ChineseData.Fuzzy.entries.filter { it.name in fuzzy }.joinToString(", ") { it.label.replace(" ", "") }
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
    val on by Prefs.flow(context, Prefs.FUZZY).collectAsState(Prefs[Prefs.FUZZY])
    Card {
        ChineseData.Fuzzy.entries.forEach { mode ->
            SwitchItem(mode.label, null, mode.name in on) { enabled ->
                val names = if (enabled) on + mode.name else on - mode.name
                Prefs.set(context, Prefs.FUZZY, names)
                ChineseData.setFuzzy(context, ChineseData.Fuzzy.entries.filter { it.name in names }.toSet())
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
        val ms by Prefs.flow(context, Prefs.LONG_PRESS_MS).collectAsState(Prefs[Prefs.LONG_PRESS_MS])
        Column(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp)) {
            Text(stringResource(R.string.settings_long_press), fontSize = 18.sp, fontWeight = FontWeight.Medium, color = Ink)
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.settings_long_press_ms, ms), fontSize = 13.sp, color = Ink, modifier = Modifier.width(72.dp))
                Slider(
                    value = ms.toFloat(), valueRange = 100f..700f, steps = 11,
                    onValueChange = { Prefs.set(context, Prefs.LONG_PRESS_MS, ((it / 50).roundToInt() * 50)) },
                )
            }
        }
    }
    SectionTag(stringResource(R.string.sebtype_settings_feedback))
    Card {
        PrefSwitch(stringResource(R.string.settings_key_popup), option = Prefs.KEY_POPUP)
        PrefSwitch(stringResource(R.string.settings_vibrate), option = Prefs.VIBRATE)
        PrefSwitch(stringResource(R.string.settings_sound), option = Prefs.SOUND)
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
        NavItem(stringResource(R.string.sebtype_settings_help), stringResource(R.string.sebtype_settings_help_subtitle)) {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/S-Sebb/SebType/issues")))
        }
        NavItem(stringResource(R.string.sebtype_settings_credits), stringResource(R.string.settings_credits_subtitle)) { nav.go("credits") }
    }
}

/** One line of assets/credits.tsv: a component the app ships, its licence and where it comes from. */
private data class Component(val name: String, val licence: String, val url: String)

/** The licences and credits: one list of what the app is built from (assets/credits.tsv, #254). */
@Composable
fun CreditsScreen(nav: Nav) = Screen(stringResource(R.string.sebtype_settings_credits), nav::back) {
    val context = LocalContext.current
    val components = remember {
        context.assets.open("credits.tsv").bufferedReader().readLines()
            .filter { it.isNotBlank() && !it.startsWith("#") }
            .map { line -> line.split('\t').let { Component(it[0], it[1], it[2]) } }
    }
    Text(stringResource(R.string.settings_credits_intro), fontSize = 15.sp, color = Ink,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 12.dp))
    SectionTag(stringResource(R.string.settings_credits_tag))
    Card {
        components.forEach { c ->
            Item(c.name, "${c.licence} · ${c.url.removePrefix("https://")}",
                Modifier.clickable { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(c.url))) })
        }
    }
}
