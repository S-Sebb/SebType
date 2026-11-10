package org.futo.inputmethod.engine.general

import android.content.Context
import android.os.SystemClock
import android.util.Log
import android.view.KeyCharacterMap
import android.view.KeyEvent
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import androidx.datastore.preferences.core.stringPreferencesKey
import icu.astronot233.rime.DeployStage
import icu.astronot233.rime.Rime
import icu.astronot233.rime.RimeMessage
import icu.astronot233.rime.RimeSchema
import icu.astronot233.rime.SyncStage
import icu.astronot233.rime.X11Keys.XK_BackSpace
import icu.astronot233.rime.X11Keys.XK_Linefeed
import icu.astronot233.rime.X11Keys.XK_Return
import icu.astronot233.rime.X11Keys.XK_Tab
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.withContext
import org.futo.inputmethod.engine.ExpandableSuggestionBarConfiguration
import org.futo.inputmethod.engine.GlobalIMEMessage
import org.futo.inputmethod.engine.IMEHelper
import org.futo.inputmethod.engine.IMEInterface
import org.futo.inputmethod.engine.IMEMessage
import org.futo.inputmethod.engine.MenuSwitch
import org.futo.inputmethod.event.Event
import org.futo.inputmethod.latin.R
import org.futo.inputmethod.latin.Subtypes.switchToNextLanguage
import org.futo.inputmethod.latin.SuggestedWords
import org.futo.inputmethod.latin.SuggestedWords.SuggestedWordInfo
import org.futo.inputmethod.latin.SuggestionBlacklist
import org.futo.inputmethod.latin.common.Constants
import org.futo.inputmethod.latin.common.InputPointers
import org.futo.inputmethod.latin.settings.Settings
import org.futo.inputmethod.latin.suggestions.SuggestionStripViewAccessor
import org.futo.inputmethod.latin.uix.FileKind
import org.futo.inputmethod.latin.uix.FloatingPreEdit
import org.futo.inputmethod.latin.uix.PreEditListener
import org.futo.inputmethod.latin.uix.SettingsKey
import org.futo.inputmethod.latin.uix.actions.throwIfDebug
import org.futo.inputmethod.latin.uix.getSetting
import org.futo.inputmethod.latin.uix.namePreferenceKeyFor
import org.futo.inputmethod.latin.uix.preferenceKeyFor
import org.futo.inputmethod.latin.uix.setSetting
import org.futo.inputmethod.latin.uix.settings.CollapsibleSection
import org.futo.inputmethod.latin.uix.settings.DropDownPickerSettingItem
import org.futo.inputmethod.latin.uix.settings.SettingToggleRaw
import org.futo.inputmethod.latin.uix.settings.UserSetting
import org.futo.inputmethod.latin.uix.settings.UserSettingsMenu
import org.futo.inputmethod.latin.uix.settings.useDataStore
import org.futo.inputmethod.latin.utils.ZipFileHelper
import org.futo.inputmethod.latin.utils.toEnumOrNull
import org.futo.inputmethod.v2keyboard.KeyboardLayoutSetV2
import java.io.File
import java.util.Locale
import kotlin.math.max
import kotlin.math.min

object ChineseIMESettings {
    enum class ChineseSimplificationMode(val stringResource: Int) {
        // These must not be renamed, or the existing setting value for users will break
        ByLanguage(R.string.chinese_setting_simplification_simplify_by_language_country),
        Simplified(R.string.chinese_setting_simplification_force_simplified),
        Traditional(R.string.chinese_setting_simplification_force_traditional);
    }

    enum class PinyinScheme(
        val displayNameZH: String,
        val displayNameEN: String,
        val rimeId: String
    ) {
        // These must not be renamed, or the existing setting value for users will break
        FullPinyin("全拼", "Full Pinyin", "luna_pinyin"),
        Natural("自然碼雙拼", "Double Pinyin", "double_pinyin"),
        ABC("智能ABC雙拼", "Double Pinyin - ABC", "double_pinyin_abc"),
        FlyPY("小鶴雙拼", "Double Pinyin - flyPY", "double_pinyin_flypy"),
        MS("微軟雙拼", "Double Pinyin - MS", "double_pinyin_mspy"),
        PYJJ("拼音加加雙拼", "Double Pinyin - PYJJ", "double_pinyin_pyjj"),
        ST("四通雙拼", "Double Pinyin - ST", "double_pinyin_st");
    }

    internal fun initialPatch(pattern: String, substitution: String, twoWay: Boolean)
            = buildList {
        add("derive/^${pattern}/${substitution}/")
        if(twoWay) add("derive/^${substitution}/${pattern}/")
    }

    internal fun finalPatch(pattern: String, substitution: String, twoWay: Boolean)
            = buildList {
        add("derive/${pattern}$/${substitution}/")
        if(twoWay) add("derive/${substitution}$/${pattern}/")
    }

    enum class FuzzyPinyinModes(val schemePatch: List<String>, val displayName: String) {
        // These must not be renamed, or the existing setting value for users will break
        Z_ZH(initialPatch("z", "zh", true), "z = zh"),
        C_CH(initialPatch("c", "ch", true), "c = ch"),
        S_SH(initialPatch("s", "sh", true), "s = sh"),
        L_N(initialPatch("l", "n", true), "l = n"),
        F_H(initialPatch("f", "h", true), "f = h"),
        R_L(initialPatch("r", "l", false), "r = l"),
        K_G(initialPatch("k", "g", false), "k = g"),

        AN_ANG(finalPatch("an", "ang", true), "an = ang"),
        EN_ENG(finalPatch("en", "eng", true), "en = eng"),
        IN_ING(finalPatch("in", "ing", true), "in = ing"),
        IAN_IANG(finalPatch("ian", "iang", true), "ian = iang"),
        UAN_UANG(finalPatch("uan", "uang", true), "uan = uang");

        companion object {
            @JvmStatic
            fun fromCommaString(str: String) =
                str.split(',').mapNotNull { it.toEnumOrNull<FuzzyPinyinModes>() }.toSet()

            @JvmStatic
            fun toCommaString(value: Set<FuzzyPinyinModes>) =
                value.joinToString(",") { it.name }
        }
    }

    val SimplificationSetting = SettingsKey(
        stringPreferencesKey("ChineseIME_simplification"),
        ChineseSimplificationMode.ByLanguage.name
    )

    val PinyinSchemeSetting = SettingsKey(
        stringPreferencesKey("ChineseIME_pinyin_scheme"),
        PinyinScheme.FullPinyin.name
    )

    val FuzzyPinyinSetting = SettingsKey(
        stringPreferencesKey("ChineseIME_fuzzy_pinyin"),
        ""
    )

    var schemaList: List<RimeSchema> = emptyList()
    val menu = UserSettingsMenu(
        title = R.string.chinese_settings_title,
        searchTags = R.string.chinese_setting_search_tags,
        navPath = "ime/zh", registerNavPath = true,
        settings = listOf(
            UserSetting(R.string.chinese_setting_simplification) {
                val resources = LocalResources.current
                val (setting, setSetting) = useDataStore(SimplificationSetting)
                DropDownPickerSettingItem<ChineseSimplificationMode>(
                    stringResource(R.string.chinese_setting_simplification),
                    ChineseSimplificationMode.entries,
                    setting.toEnumOrNull<ChineseSimplificationMode>() ?: ChineseSimplificationMode.ByLanguage,
                    { setSetting(it.name) },
                    { resources.getString(it.stringResource) }
                )
            },

            UserSetting(R.string.chinese_setting_pinyin_scheme) {
                val context = LocalContext.current
                val resources = LocalResources.current
                val (setting, setSetting) = useDataStore(PinyinSchemeSetting)

                val availableEntries = remember {
                    val sharedDir = ChineseIME.getShared(context)
                    val files = (sharedDir.listFiles() ?: emptyArray()).map { it.name.split('.').first() }.toSet()
                    PinyinScheme.entries.filter {
                        files.contains(it.rimeId) || it == PinyinScheme.FullPinyin
                    }
                }
                DropDownPickerSettingItem<PinyinScheme>(
                    stringResource(R.string.chinese_setting_pinyin_scheme),
                    availableEntries,
                    setting.toEnumOrNull<PinyinScheme>() ?: PinyinScheme.FullPinyin,
                    { setSetting(it.name) },
                    { when(resources.configuration.locale.language) {
                        "zh" -> it.displayNameZH
                        else -> it.displayNameEN
                    } }
                )
            },

            UserSetting(R.string.chinese_setting_fuzzy_pinyin) {
                val (setting, setSetting) = useDataStore(FuzzyPinyinSetting)
                val set = remember(setting) { FuzzyPinyinModes.fromCommaString(setting) }

                CollapsibleSection(stringResource(R.string.chinese_setting_fuzzy_pinyin)) {
                    FuzzyPinyinModes.entries.forEach { mode ->
                        SettingToggleRaw(mode.displayName, set.contains(mode), { enabled ->
                            val newSet = if (enabled) {
                                set + setOf(mode)
                            } else {
                                set - setOf(mode)
                            }

                            setSetting(FuzzyPinyinModes.toCommaString(newSet))
                        })
                    }
                }

            },

        )
    )
}

class InputKeeper() {
    var text = ""
        private set

    fun clear() {
        text = ""
    }

    fun append(codepoint: Int) {
        text += Char(codepoint)
    }

    fun backspace() {
        if(text.isNotEmpty()) text = text.take(text.length - 1)
    }

    fun replace(with: String) {
        text = with
    }
}

class ChineseIME(val helper: IMEHelper) : IMEInterface, SuggestionStripViewAccessor, PreEditListener {
    private val TAG = "ChineseIME (rime)"

    // The process's Rime, shared with the background setup (RimeIceSetup)
    private val rime: Rime get() = RimeIceSetup.rime(helper.context)
    private val connect get() = helper.getCurrentInputConnection()
    private val coroScope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private val expandableUiCfg = ExpandableSuggestionBarConfiguration(true, false)
    private val maxBufferLength = 0x100000
    private var layoutHint: String? = null
    private val rawInput = InputKeeper()
    private val currentTransformation get() = when(layoutHint) {
        "stroke" -> StrokeTransformation
        else -> emptyMap()
    }

    private enum class EditingState(val active: Boolean) {
        NotEditing(false),
        Editing(true),
        Finishing(false)
    }
    private var editingState = EditingState.NotEditing

    companion object {
        /** rime-ice's 简/繁 switch, the one Ctrl+Shift+F toggles on the PCs */
        private const val TRADITIONAL = "traditionalization"

        @JvmStatic
        private val StrokeTransformation = mapOf(
            'h' to '⼀',
            's' to '⼁',
            'p' to '⼃',
            'n' to '⼂',
            'z' to '⼄',
        )

        @JvmStatic
        fun getRimeDir(context: Context) = context.getExternalFilesDir("rime")
                ?: throw IllegalStateException("Failed to access ExternalFilesDir!")

        @JvmStatic
        fun getShared(context: Context) = File(getRimeDir(context), "shared")

        @JvmStatic
        fun getUser(context: Context) = File(getRimeDir(context), "user")

        val PreviouslyExtractedDictionaryName = SettingsKey(
            stringPreferencesKey("ChineseDictionaryExtractedValue"),
            ""
        )
        var localPrevExtractedDictionaryName: String? = null

        fun resetSharedFromResources(context: Context, scope: CoroutineScope): Boolean {
            val pref = FileKind.Dictionary.preferenceKeyFor("zh")
            val namePref = FileKind.Dictionary.namePreferenceKeyFor("zh")
            val filePath = context.getSetting(pref, "")
            val file = File(context.applicationContext.getExternalFilesDir(null), filePath)

            val name = context.getSetting(namePref, "?")



            if((localPrevExtractedDictionaryName ?: context.getSetting(PreviouslyExtractedDictionaryName)) == name) {
                return false
            }

            try {
                val shared = getShared(context)
                shared.walkBottomUp()
                    .fold(true) { res, it -> (it == shared || it.delete() || !it.exists()) && res }

                // We are intentionally checking this only after deleting the shared directory
                // This is because if the user deletes the dictionary file, we want to apply
                // the deletion (TODO: It doesn't apply)
                if(filePath.isEmpty()) return true
                if(!file.exists()) return true

                ZipFileHelper.extract(file, shared)

                return true
            } finally {
                localPrevExtractedDictionaryName = name
                scope.launch(Dispatchers.IO) {
                    context.setSetting(PreviouslyExtractedDictionaryName.key, name)
                }
            }
        }
    }

    private fun handlePassByMessage(x11Code: Int, mask: Int) {
        when (x11Code) {
            XK_BackSpace -> sendDownUpKeyEvent(KeyEvent.KEYCODE_DEL, 0)
            XK_Tab       -> sendDownUpKeyEvent(KeyEvent.KEYCODE_TAB, 0)
            XK_Linefeed  -> sendDownUpKeyEvent(KeyEvent.KEYCODE_ENTER, 0)
            XK_Return    -> sendDownUpKeyEvent(KeyEvent.KEYCODE_ENTER, 0)
            else -> {
                if (!ready || rime.preeditFlow.value.isEmpty() || editingState.active) {
                    connect?.commitText(String(Character.toChars(x11Code)), 1)
                } else {
                    coroScope.launch {
                        rime.commitComposition()
                        rime.processX11Code(x11Code, mask)
                    }
                }
            }
        }
    }

    private fun subscribeToRimeMessage() = rime.messageFlow.onEach { msg -> when (msg) {
        is RimeMessage.Deploy -> when (msg.value) {
            DeployStage.Unknown -> Log.e(TAG, "Deploy: Failed")
            DeployStage.Startup -> Log.i(TAG, "Deploy: Startup")
            DeployStage.Success -> {
                Log.i(TAG, "Deploy: Success")
                coroScope.launch {
                    ChineseIMESettings.schemaList = rime.getSchemata().also {
                        Log.d(TAG, "Schemas: ${it.joinToString { it.toString() }} ")
                    }
                }
            }
            else -> {}
        }
        is RimeMessage.Sync -> when (msg.value) {
            SyncStage.Unknown -> Log.e(TAG, "Sync: Failed")
//            SyncStage.Startup ->
//            SyncStage.Success ->
            else -> {}
        }
        is RimeMessage.Commit -> {
            connect?.commitText(msg.value, 1)
        }
        is RimeMessage.Passby -> {
            val (x11Code, mask) = msg.value
            handlePassByMessage(x11Code, mask)
        }
        is RimeMessage.Unknown -> {
            Log.e(TAG, "Unrecognized error occurred: ${msg.value}")
        }
    }}.launchIn(coroScope)

    private fun subscribeToRimePreedit() = rime.preeditFlow.onEach { ped ->
        if(!ready) return@onEach
        val notEditing = editingState == EditingState.NotEditing
        if(ped.isEmpty() && notEditing) { rawInput.clear() }

        helper.updateUiInputState(ped.isEmpty() && notEditing)
        helper.setPreedit(FloatingPreEdit.build(ped, this, currentTransformation, rawInput.text))
    }.launchIn(coroScope)

    override fun onStartEdit() {
        editingState = EditingState.Editing
    }

    // This assumes that the only valid characters for input simulation are ASCII letters
    // In particular, some characters like space will break the input by ending composition
    // (Maybe there are other valid symbols potentially?)
    private fun safeguardInputStringForSimulation(input: String): String {
        var string = input
        string = string.filter { it in 'a'..'z' || it in 'A'..'Z' }
        return string
    }

    private var updateEditJob: Job? = null
    override fun onUpdateEdit(string: String) {
        updateEditJob?.cancel()
        updateEditJob = coroScope.launch {
            ensureActive()
            rime.clearComposition()

            val converted = safeguardInputStringForSimulation(string)
            ensureActive()
            rime.simulateKeySequence(converted)
            rawInput.replace(converted)
        }
    }

    private var waitingToSelect: Pair<String, Int>? = null
    override fun onFinishEdit(string: String, candidateWord: String?, candidateIndex: Int?) {
        if(!editingState.active) return
        editingState = EditingState.Finishing

        coroScope.launch {
            rime.clearComposition()

            if(candidateWord != null && candidateIndex != null) {
                // TODO: This is kind of a buggy way of doing it
                waitingToSelect = candidateWord to candidateIndex
            }

            val converted = safeguardInputStringForSimulation(string)
            rime.simulateKeySequence(converted)
            rawInput.replace(converted)

            editingState = EditingState.NotEditing

            if(string.isEmpty()) {
                showSuggestionStrip(
                    SuggestedWords(
                        ArrayList(emptyList()),
                        ArrayList(emptyList()),
                        null,
                        false,
                        false,
                        false,
                        0,
                        0,
                        0
                    )
                )
            }
        }
    }

    private fun subscribeToRimeCandidates() = rime.candidatesFlow.onEach { cdd ->
        if(!ready) return@onEach
        waitingToSelect?.let { sel ->
            if(cdd.getOrNull(sel.second)?.text == sel.first) {
                if(rime.selectCandidate(sel.second)) {
                    waitingToSelect = null
                    return@onEach
                } else {
                    Log.e(TAG, "Error selecting candidate!")
                }
            }
        }

        val suggestWordList = cdd.mapIndexed { index, candidate -> SuggestedWordInfo(
            candidate.text,
            "",
            Int.MAX_VALUE - index,
            1,
            null,
            SuggestedWordInfo.NOT_AN_INDEX,
            SuggestedWordInfo.NOT_A_CONFIDENCE,
            index,
            candidate.comment
        ) }.let { ArrayList(it) }

        // Don't flicker an empty suggest bar when editing
        if(editingState != EditingState.NotEditing && suggestWordList.isEmpty()) {
            return@onEach
        }

        showSuggestionStrip(
            SuggestedWords(
                suggestWordList,
                suggestWordList,
                null,
                false,
                false,
                false,
                0,
                0,
                0
            )
        )
    }.launchIn(coroScope)

    override fun onCreate() {
        // Creating the Rime starts librime: off the main thread, so the keyboard draws at once.
        coroScope.launch {
            withContext(Dispatchers.IO) { RimeIceSetup.rime(helper.context) }
            subscribeToRimeMessage()
            subscribeToRimePreedit()
            subscribeToRimeCandidates()
        }
        RimeIceSetup.state.onEach { if(helper.isImeActive(this)) showSetupState(it) }.launchIn(coroScope)

        helper.lifecycleScope.launch {
            GlobalIMEMessage.collect { message ->
                when(message) {
                    IMEMessage.ReloadResources -> coroScope.launch {
                        RimeIceSetup.whileStopped(helper.context) {}
                        prevConfiguration = null
                    }
                    else -> {}
                }
            }
        }

        blacklist.init()
    }
    override fun onDestroy() {
        helper.lifecycleScope.cancel()
        coroScope.cancel()
        // The shared Rime keeps running for the next Chinese keyboard, until it is idle too long.
        RimeIceSetup.setInUse(helper.context, false)
    }

    override fun onLanguageLeft() = RimeIceSetup.setInUse(helper.context, false)

    override fun onStartInput() {
        RimeIceSetup.setInUse(helper.context, true)
        showSetupState(RimeIceSetup.state.value)
        updateConfig()
    }

    private var prevConfiguration: RimeIceSetup.Configuration? = null

    // SebType (#36): the menu's 简/繁 switch. It saves the choice as the simplification setting and turns
    // rime-ice's traditionalization option on or off at once, with no new deploy. The option converts
    // only what Rime outputs, so learned words stay the same in both.
    private val traditional = mutableStateOf(false)

    override fun getMenuSwitch() = MenuSwitch("简体", "繁體", traditional.value) { on ->
        traditional.value = on
        coroScope.launch {
            helper.context.setSetting(ChineseIMESettings.SimplificationSetting,
                if(on) ChineseIMESettings.ChineseSimplificationMode.Traditional.name
                else ChineseIMESettings.ChineseSimplificationMode.Simplified.name)
            if(ready) rime.setOption(TRADITIONAL, on)
        }
    }

    // Rime takes keys and its candidates show only once it is set up for this keyboard's configuration.
    private val ready get() = prevConfiguration != null && RimeIceSetup.state.value == RimeIceSetup.State.Ready

    private var configSemaphore = Semaphore(1)
    private fun updateConfig() {
        coroScope.launch {
            if(editingState.active) return@launch
            if(!configSemaphore.tryAcquire()) return@launch

            try {
                val settings = Settings.getInstance().current
                val pinyinScheme = helper.context.getSetting(ChineseIMESettings.PinyinSchemeSetting)
                    .toEnumOrNull<ChineseIMESettings.PinyinScheme>()
                    ?: ChineseIMESettings.PinyinScheme.FullPinyin
                val schema = RimeIceSetup.schemaFor(layoutHint, pinyinScheme) ?: return@launch
                traditional.value = !RimeIceSetup.isSimplifiedChinese(helper.context, settings.mLocale)

                val config = RimeIceSetup.Configuration(
                    schema,
                    learning = settings.isPersonalizationEnabled,
                    fuzzyMode = ChineseIMESettings.FuzzyPinyinModes.fromCommaString(
                        helper.context.getSetting(ChineseIMESettings.FuzzyPinyinSetting)
                    )
                )
                if(config == prevConfiguration && ready) {
                    rime.setOption(TRADITIONAL, traditional.value)
                    return@launch
                }

                prevConfiguration = null
                // Joins a setup already running in the background (setup screen, app update).
                if(RimeIceSetup.ensure(helper.context, config)) {
                    rime.setOption(TRADITIONAL, traditional.value)
                    prevConfiguration = config
                    if(helper.isImeActive(this@ChineseIME)) setNeutralSuggestionStrip()
                }
            } catch(e: CancellationException) {
                throw e
            } catch(e: Exception) {
                Log.e(TAG, "Setting up Rime failed", e)
                if(helper.isImeActive(this@ChineseIME)) showNotice(R.string.sebtype_chinese_engine_failed)
            } finally {
                configSemaphore.release()
            }
        }
    }

    // While Chinese is set up the suggestion bar says so (the keys type plain letters meanwhile). A
    // failed deploy or self-test shows a notice instead of a silently dead engine; tapping it
    // reinstalls the bundled rime-ice and deploys again. Learned words are kept.
    private fun showSetupState(state: RimeIceSetup.State) = when(state) {
        is RimeIceSetup.State.Preparing ->
            if(state.percent == null) showNotice(R.string.sebtype_chinese_preparing)
            else showNotice(R.string.sebtype_chinese_preparing_percent, state.percent)
        RimeIceSetup.State.Failed -> showNotice(R.string.sebtype_chinese_engine_failed)
        RimeIceSetup.State.Ready -> {}
    }

    private fun showNotice(text: Int, vararg args: Any) = showSuggestionStrip(SuggestedWords(
        arrayListOf(SuggestedWordInfo(
            helper.context.getString(text, *args),
            "",
            Int.MAX_VALUE,
            SuggestedWordInfo.KIND_HARDCODED,
            null,
            SuggestedWordInfo.NOT_AN_INDEX,
            SuggestedWordInfo.NOT_A_CONFIDENCE
        )),
        null,
        null,
        false,
        false,
        false,
        0,
        0
    ))

    private fun retryAfterFailure() {
        coroScope.launch {
            withContext(Dispatchers.IO) { RimeIceBundle.forget(helper.context) }
            prevConfiguration = null
            updateConfig()
        }
    }

    override fun onLayoutUpdated(layout: KeyboardLayoutSetV2) {
        layoutHint = layout.mainLayout.imeHint
        if(helper.isImeActive(this)) updateConfig()
    }

    override fun onFinishInput() {
        if(editingState.active || !ready) return
        coroScope.launch {
            waitingToSelect = null
            rawInput.clear()
            rime.clearComposition()
        }
    }

    override fun onFinishSlidingInput() {
    }

    private fun interruptInput(text: CharSequence? = null) {
        if(ready) coroScope.launch {
            rawInput.clear()
            rime.clearComposition()
        }
        connect?.finishComposingText()
        if (text != null) {
            connect?.commitText(text, 1)
        }
    }

    private fun sendDownUpKeyEvent(keyCode: Int, metaState: Int = 0) {
        // NOTE: Modified based on InputLogic
        val eventTime = SystemClock.uptimeMillis()
        connect?.sendKeyEvent(
            KeyEvent(
                eventTime, eventTime,
                KeyEvent.ACTION_DOWN, keyCode, 0, metaState, KeyCharacterMap.VIRTUAL_KEYBOARD, 0,
                KeyEvent.FLAG_SOFT_KEYBOARD or KeyEvent.FLAG_KEEP_TOUCH_MODE
            )
        )
        connect?.sendKeyEvent(
            KeyEvent(
                eventTime, eventTime,
                KeyEvent.ACTION_UP, keyCode, 0, metaState, KeyCharacterMap.VIRTUAL_KEYBOARD, 0,
                KeyEvent.FLAG_SOFT_KEYBOARD or KeyEvent.FLAG_KEEP_TOUCH_MODE
            )
        )
    }
    private fun triggerIfIsAction(keyCode: Int): Boolean {
        if (Constants.CODE_ACTION_0 <= keyCode && keyCode <= Constants.CODE_ACTION_MAX) {
            val actionId: Int = keyCode - Constants.CODE_ACTION_0
            helper.triggerAction(actionId, false)
            return true
        }
        if (Constants.CODE_ALT_ACTION_0 <= keyCode && keyCode <= Constants.CODE_ALT_ACTION_MAX) {
            val actionId: Int = keyCode - Constants.CODE_ALT_ACTION_0
            helper.triggerAction(actionId, true)
            return true
        }
        return false
    }
    override fun onEvent(event: Event) {
        helper.requestCursorUpdate()
        when (event.eventType) {
            Event.EVENT_TYPE_INPUT_KEYPRESS,
            Event.EVENT_TYPE_INPUT_KEYPRESS_RESUMED -> {
                if (triggerIfIsAction(event.mKeyCode))
                    return
                val x11Code = when (event.mKeyCode) {
                    Constants.CODE_DELETE -> '\b'.code
                    Event.NOT_A_KEY_CODE -> event.mCodePoint
                    else -> return
                }.let { when (it) {
                    '\b'.code -> XK_BackSpace
                    '\t'.code -> XK_Tab
                    '\n'.code -> XK_Return // Use return instead of linefeed here.
                    '\r'.code -> XK_Return
                    else -> it
                } }

                if(!ready) {
                    handlePassByMessage(x11Code, 0)
                } else if(!editingState.active) {
                    // Only update outside editing state. We cannot update inside editing state,
                    // because the cursor position is unknown and we assume it's always at the end
                    if(x11Code == XK_BackSpace) {
                        rawInput.backspace()
                    } else if(x11Code == XK_Return || x11Code == ' '.code) {
                        rawInput.clear()
                    } else if(event.mKeyCode == Event.NOT_A_KEY_CODE) {
                        rawInput.append(event.mCodePoint)
                    }

                    coroScope.launch { rime.processX11Code(x11Code) }
                } else {
                    handlePassByMessage(x11Code, 0)
                }
            }

            Event.EVENT_TYPE_SUGGESTION_PICKED -> {
                val suggestion = event.mSuggestedWordInfo ?: return
                if (!ready) {
                    // The setup notice; only the failure notice does something.
                    if (RimeIceSetup.state.value == RimeIceSetup.State.Failed) retryAfterFailure()
                } else if (suggestion.isKindOf(SuggestedWordInfo.KIND_UNDO)) {
                    connect?.commitText(suggestion.word, 1)
                } else {
                    coroScope.launch {
                        if(!rime.selectCandidate(suggestion.mCandidateIndex)) {
                            Log.e(TAG, "Couldn't select candidate")
                        }
                    }
                }
            }

            Event.EVENT_TYPE_SOFTWARE_GENERATED_STRING -> {
                interruptInput(event.mText)
            }

            Event.EVENT_TYPE_DOWN_UP_KEYEVENT -> {
                interruptInput()
                if (event.mX == KeyEvent.META_CTRL_ON) when (event.mKeyCode) {
                    KeyEvent.KEYCODE_F1 -> {

                    }
                    KeyEvent.KEYCODE_F2 -> {
                        Log.d(TAG, "Redeploying...")
                        coroScope.launch { rime.deploy() }
                        return
                    }
                }
                sendDownUpKeyEvent(event.mKeyCode, event.mX)
            }

            else -> {}
        }
    }

    private var anchorOutOfDate = true
    private var anchorLeftCount = 0
    private var anchorRightCount = 0
    private val currentAnchorCursor: Pair<Int, Int> get() {
        if (anchorOutOfDate) {
            anchorLeftCount = (connect?.getTextBeforeCursor(maxBufferLength, 0) ?: "").length
            anchorRightCount = (connect?.getTextAfterCursor(maxBufferLength, 0) ?: "").length
            currentMovingCursor = anchorLeftCount
            anchorOutOfDate = false
        }
        return Pair(anchorLeftCount, anchorRightCount)
    }
    private var currentMovingCursor: Int = 0
    override fun onMovePointer(steps: Int, stepOverWords: Boolean, select: Boolean?) {
        var meta = 0
        if (stepOverWords) meta = meta or KeyEvent.META_CTRL_ON
        if (select == true) meta = meta or KeyEvent.META_SHIFT_ON
        if(steps < 0) {
            for(i in 0 until -steps) {
                sendDownUpKeyEvent(KeyEvent.KEYCODE_DPAD_LEFT, meta)
            }
        } else {
            for(i in 0 until steps) {
                sendDownUpKeyEvent(KeyEvent.KEYCODE_DPAD_RIGHT, meta)
            }
        }
    }
    override fun onUpWithPointerActive() {
        // TODO("Unsupported yet")
    }
    override fun onMoveDeletePointer(steps: Int) {
        setNeutralSuggestionStrip()
        val (lBound, rBound) = currentAnchorCursor
        currentMovingCursor = when {
            steps < 0 -> max(0, currentMovingCursor - 1)
            steps > 0 -> min(lBound + rBound, currentMovingCursor + 1)
            else -> currentMovingCursor
        }
        connect?.setSelection(lBound, currentMovingCursor)
    }
    override fun onUpWithDeletePointerActive() {
        anchorOutOfDate = true
        val selection: CharSequence? = connect?.getSelectedText(0)
        if (selection == null) {
            onUpWithPointerActive()
            return
        }
        coroScope.launch {
            val preedit = rime.getPreedit()
            var reserved: String
            when {
                preedit.endsWith(selection) -> {
                    reserved = preedit.removeSuffix(selection).filterNot { it.isWhitespace() }
                    connect?.commitText(reserved, 1)
                }
                selection.endsWith(preedit) -> {
                    reserved = selection.removeSuffix(preedit) as String
                    sendDownUpKeyEvent(KeyEvent.KEYCODE_DEL, 0)
                }
                else -> {
                    sendDownUpKeyEvent(KeyEvent.KEYCODE_DEL, 0)
                    Log.w(TAG, "Wrong preedit text fetched?")
                    return@launch
                }
            }
            rawInput.clear()
            rime.clearComposition()
            val info = arrayListOf(SuggestedWordInfo(
                reserved,
                "",
                Int.MAX_VALUE,
                SuggestedWordInfo.KIND_UNDO,
                null,
                0,
                0
            ))
            showSuggestionStrip(SuggestedWords(
                info,
                null,
                null,
                false,
                false,
                false,
                0,
                0
            ))
        }
    }

    override fun onSwipeLanguage(direction: Int) {
        switchToNextLanguage(helper.context, direction)
    }

    private var prevSuggest: SuggestedWords? = null
    private val blacklist = SuggestionBlacklist(Settings.getInstance(), helper.context, helper.lifecycleScope)
    override fun setNeutralSuggestionStrip() {
        prevSuggest = null
        helper.setNeutralSuggestionStrip(expandableUiCfg)
    }
    override fun showSuggestionStrip(suggestedWords: SuggestedWords?) {
        val words = suggestedWords?.let { blacklist.filterBlacklistedSuggestions(it) }
        prevSuggest = words
        helper.showSuggestionStrip(words, expandableUiCfg)
    }

    override fun requestSuggestionRefresh() {
        showSuggestionStrip(null)
    }

    override fun isGestureHandlingAvailable() : Boolean = false
    override fun onCustomRequest(requestCode: Int): Boolean = false
    override fun onMovingCursorLockEvent(canMoveCursor: Boolean) {}

    override fun clearUserHistoryDictionaries() {
        Log.d(TAG, "Clearing Chinese dictionary...")

        coroScope.launch {
            RimeIceSetup.whileStopped(helper.context) {
                getUser(helper.context).let {
                    it.deleteRecursively()
                    it.mkdirs()
                }
            }
            prevConfiguration = null
            if(helper.isImeActive(this@ChineseIME)) updateConfig()
        }
    }

    override fun onStartBatchInput() {}
    override fun onUpdateBatchInput(batchPointers: InputPointers?) {}
    override fun onEndBatchInput(batchPointers: InputPointers?) {}
    override fun onCancelBatchInput() {}

// Non-behavior methods {{
// NOTE: These methods are scheduled to have no behavior
    override fun onCancelInput() {}
    override fun onDeviceUnlocked() {}
    override fun onOrientationChanged() {}
    override fun onUpdateSelection(oldSelStart: Int, oldSelEnd: Int, newSelStart: Int, newSelEnd: Int, composingSpanStart: Int, composingSpanEnd: Int) {}
// Non-behavior methods }}

    val debugInfo: String
        get() = "configuration=${prevConfiguration}\nlayoutHint=${layoutHint}\nlocale=${Settings.getInstance().current.mLocale}\nisSimplified=${RimeIceSetup.isSimplifiedChinese(helper.context, Settings.getInstance().current.mLocale)}\nrawInput=${rawInput.text}"
}