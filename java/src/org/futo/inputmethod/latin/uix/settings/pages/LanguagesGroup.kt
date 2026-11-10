package org.futo.inputmethod.latin.uix.settings.pages

import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.offset
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import androidx.navigation.NavHostController
import kotlin.math.roundToInt
import kotlinx.coroutines.flow.map
import org.futo.inputmethod.engine.general.ChineseIMESettings
import org.futo.inputmethod.engine.general.ChineseOptions
import org.futo.inputmethod.engine.general.JapaneseIMESettings
import org.futo.inputmethod.latin.R
import org.futo.inputmethod.latin.SebTypeLanguages
import org.futo.inputmethod.latin.Subtypes
import org.futo.inputmethod.latin.SubtypesSetting
import org.futo.inputmethod.latin.settings.Settings
import org.futo.inputmethod.latin.stripExtensionsIfNeeded
import org.futo.inputmethod.latin.toLocale
import org.futo.inputmethod.latin.uix.SHOW_EMOJI_SUGGESTIONS
import org.futo.inputmethod.latin.uix.dataStore
import org.futo.inputmethod.latin.uix.setSettingBlocking
import org.futo.inputmethod.latin.uix.settings.BottomSpacer
import org.futo.inputmethod.latin.uix.settings.NavigationItem
import org.futo.inputmethod.latin.uix.settings.NavigationItemStyle
import org.futo.inputmethod.latin.uix.settings.Route
import org.futo.inputmethod.latin.uix.settings.ScreenTitle
import org.futo.inputmethod.latin.uix.settings.ScrollableList
import org.futo.inputmethod.latin.uix.settings.SettingItem
import org.futo.inputmethod.latin.uix.settings.SettingToggleDataStore
import org.futo.inputmethod.latin.uix.settings.SettingToggleRaw
import org.futo.inputmethod.latin.uix.settings.SettingToggleSharedPrefs
import org.futo.inputmethod.latin.uix.settings.Tip
import org.futo.inputmethod.latin.uix.settings.useDataStore
import org.futo.inputmethod.latin.uix.settings.useDataStoreValue

// SebType's Languages group (#41): the globe order, then each language's own options on one screen.

/** One of SebType's three languages and its keyboard subtype; [subtype] is null while it's off. */
private data class GlobeLanguage(val language: String, val canonical: String, val subtype: String?)

private val GlobeNames = mapOf("en" to "English", "zh" to "中文 Chinese", "ja" to "日本語 Japanese")
private val GlobeShortNames = mapOf("en" to "EN", "zh" to "中", "ja" to "日")

private fun languageOf(subtype: String) = Subtypes.getLocale(Subtypes.convertToSubtype(subtype)).language

/** The languages that are on, in globe order, then the ones that are off. */
private fun globeLanguages(subtypes: List<String>): List<GlobeLanguage> {
    val all = SebTypeLanguages.map { (locale, layout) ->
        val canonical = Subtypes.subtypeToString(
            Subtypes.makeSubtype(locale.toLocale().stripExtensionsIfNeeded().toString(), layout))
        GlobeLanguage(languageOf(canonical), canonical, null)
    }
    val on = subtypes.mapNotNull { s -> all.find { it.language == languageOf(s) }?.copy(subtype = s) }
        .distinctBy { it.language }
    return on + all.filter { a -> on.none { it.language == a.language } }
}

/**
 * The subtypes in globe order. FUTO's settings cache and setting flows compare sets, which ignores
 * their order, so they miss a reorder.
 */
@Composable
fun useSubtypesInOrder(): List<String> {
    val context = LocalContext.current
    val initial = useDataStoreValue(SubtypesSetting)
    return remember { context.dataStore.data.map { (it[SubtypesSetting.key] ?: SubtypesSetting.default).toList() } }
        .collectAsState(initial.toList()).value
}

/** "EN → 中 → 日", the languages the globe key cycles through. */
fun globeOrderSummary(subtypes: List<String>) =
    globeLanguages(subtypes).filter { it.subtype != null }.joinToString(" → ") { GlobeShortNames[it.language]!! }

@Composable
private fun GlobeOrder() {
    val context = LocalContext.current
    val subtypes = useSubtypesInOrder()
    val rows = remember(subtypes) { globeLanguages(subtypes) }
    val currentRows by rememberUpdatedState(rows)
    val onCount = rows.count { it.subtype != null }
    var dragging by remember { mutableStateOf<String?>(null) }
    var dragOffset by remember { mutableFloatStateOf(0f) }
    val rowHeight = with(LocalDensity.current) { 68.dp.toPx() }

    // The set's order is the globe order; subtypes of other languages (none on a SebType install) stay last.
    fun save(newRows: List<GlobeLanguage>) {
        val ours = newRows.mapNotNull { it.subtype }
        val new = (ours + (subtypes - ours.toSet())).distinct()
        // DataStore skips a value equal to the stored one, and sets with the same items are equal, so
        // a new order goes through a different set first. The keyboard only follows the active language.
        if(new != subtypes && new.toSet() == subtypes.toSet()) {
            context.setSettingBlocking(SubtypesSetting.key, setOf(new.first()))
        }
        context.setSettingBlocking(SubtypesSetting.key, new.toSet())
    }

    fun move(language: String, by: Int) {
        val on = currentRows.filter { it.subtype != null }.toMutableList()
        val from = on.indexOfFirst { it.language == language }
        val to = (from + by).coerceIn(0, on.size - 1)
        if(from < 0 || from == to) return
        on.add(to, on.removeAt(from))
        save(on)
    }

    Column {
        rows.forEach { row ->
            key(row.language) {
                val on = row.subtype != null
                val isDragged = dragging == row.language
                SettingItem(
                    title = GlobeNames[row.language]!!,
                    subtitle = when(row.language) {
                        "zh" -> stringResource(R.string.sebtype_settings_zh_engine)
                        "ja" -> stringResource(R.string.sebtype_settings_ja_engine)
                        else -> null
                    },
                    modifier = Modifier
                        .zIndex(if(isDragged) 1f else 0f)
                        .offset { IntOffset(0, if(isDragged) dragOffset.roundToInt() else 0) },
                    icon = {
                        Icon(
                            Icons.Default.Menu,
                            contentDescription = stringResource(R.string.sebtype_settings_drag),
                            tint = MaterialTheme.colorScheme.onBackground.copy(alpha = 0.75f),
                            modifier = if(on) Modifier.pointerInput(row.language) {
                                detectDragGestures(
                                    onDragStart = { dragging = row.language; dragOffset = 0f },
                                    onDragEnd = {
                                        move(row.language, (dragOffset / rowHeight).roundToInt())
                                        dragging = null
                                    },
                                    onDragCancel = { dragging = null },
                                    onDrag = { change, amount -> change.consume(); dragOffset += amount.y }
                                )
                            } else Modifier.alpha(0.3f)
                        )
                    }
                ) {
                    Switch(
                        checked = on,
                        // One language always stays on.
                        enabled = !(on && onCount == 1),
                        onCheckedChange = { turnOn ->
                            save(if(turnOn) {
                                currentRows.filter { it.subtype != null } + row.copy(subtype = row.canonical)
                            } else {
                                currentRows.filter { it.subtype != null && it.language != row.language }
                            })
                        }
                    )
                }
            }
        }
    }
}

@Composable
private fun FuzzyPinyinSummary(): String {
    val setting = useDataStoreValue(ChineseIMESettings.FuzzyPinyinSetting)
    val modes = ChineseIMESettings.FuzzyPinyinModes.fromCommaString(setting)
    return if(modes.isEmpty()) stringResource(R.string.sebtype_settings_off)
    else ChineseIMESettings.FuzzyPinyinModes.entries.filter { it in modes }
        .joinToString(", ") { it.displayName.replace(" ", "") }
}

@Composable
fun LanguagesScreen(navController: NavHostController) {
    ScrollableList {
        ScreenTitle(stringResource(R.string.sebtype_settings_languages), showBack = true, navController)

        ScreenTitle(stringResource(R.string.sebtype_settings_globe_order))
        Tip(stringResource(R.string.sebtype_settings_globe_order_tip))
        GlobeOrder()

        ScreenTitle("English")
        SettingToggleSharedPrefs(
            title = stringResource(R.string.sebtype_settings_autocorrect),
            key = Settings.PREF_AUTO_CORRECTION,
            default = true
        )
        SettingToggleSharedPrefs(
            title = stringResource(R.string.sebtype_settings_capitalise),
            key = Settings.PREF_AUTO_CAP,
            default = true
        )
        SettingToggleSharedPrefs(
            title = stringResource(R.string.sebtype_settings_double_space),
            key = Settings.PREF_KEY_USE_DOUBLE_SPACE_PERIOD,
            default = true
        )
        SettingToggleDataStore(
            title = stringResource(R.string.sebtype_settings_emoji_suggestions),
            setting = SHOW_EMOJI_SUGGESTIONS
        )
        NavigationItem(
            title = stringResource(R.string.sebtype_settings_my_words),
            subtitle = stringResource(R.string.sebtype_settings_my_words_en),
            style = NavigationItemStyle.Misc,
            navigate = { navController.navigate(Route.PersonalDictList("en-US")) }
        )

        ScreenTitle("中文")
        NavigationItem(
            title = stringResource(R.string.chinese_setting_fuzzy_pinyin),
            subtitle = FuzzyPinyinSummary(),
            style = NavigationItemStyle.Misc,
            navigate = { navController.navigate("zhFuzzy") }
        )
        SettingToggleDataStore(
            title = stringResource(R.string.sebtype_settings_zh_emoji),
            subtitle = stringResource(R.string.sebtype_settings_zh_emoji_subtitle),
            setting = ChineseOptions.EmojiInCandidates
        )
        SettingToggleDataStore(
            title = stringResource(R.string.sebtype_settings_zh_punctuation),
            subtitle = stringResource(R.string.sebtype_settings_zh_punctuation_subtitle),
            setting = ChineseOptions.FullWidthPunctuation
        )
        NavigationItem(
            title = stringResource(R.string.sebtype_settings_my_words),
            subtitle = stringResource(R.string.sebtype_settings_my_words_zh),
            style = NavigationItemStyle.Misc,
            navigate = { navController.navigate("zhWords") }
        )

        ScreenTitle("日本語")
        SettingToggleDataStore(
            title = stringResource(R.string.japanese_settings_toggle_halfwidth_space),
            subtitle = stringResource(R.string.japanese_settings_toggle_halfwidth_space_subtitle),
            setting = JapaneseIMESettings.HalfWidthSpace
        )
        NavigationItem(
            title = stringResource(R.string.sebtype_settings_my_words),
            subtitle = stringResource(R.string.sebtype_settings_my_words_ja),
            style = NavigationItemStyle.Misc,
            navigate = { navController.navigate(Route.PersonalDictList("ja")) }
        )

        BottomSpacer()
    }
}

/** Fuzzy pinyin's checklist: each pair of sounds that may be typed for one another. */
@Composable
fun FuzzyPinyinScreen(navController: NavHostController) {
    val (setting, setSetting) = useDataStore(ChineseIMESettings.FuzzyPinyinSetting)
    val set = remember(setting) { ChineseIMESettings.FuzzyPinyinModes.fromCommaString(setting) }
    ScrollableList {
        ScreenTitle(stringResource(R.string.chinese_setting_fuzzy_pinyin), showBack = true, navController)
        ChineseIMESettings.FuzzyPinyinModes.entries.forEach { mode ->
            SettingToggleRaw(mode.displayName, mode in set, { enabled ->
                setSetting(ChineseIMESettings.FuzzyPinyinModes.toCommaString(if(enabled) set + mode else set - mode))
            })
        }
        BottomSpacer()
    }
}
