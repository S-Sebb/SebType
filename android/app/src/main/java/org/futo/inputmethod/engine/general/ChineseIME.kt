package org.futo.inputmethod.engine.general

import android.content.Context
import android.os.SystemClock
import android.util.Log
import android.view.KeyCharacterMap
import android.view.KeyEvent
import androidx.compose.runtime.mutableStateOf
import androidx.datastore.preferences.core.stringPreferencesKey
import dev.sebb.sebtype.SebTypeConf
import dev.sebb.sebtype.core.NativeCore
import dev.sebb.sebtype.core.NativeCore.CHINESE
import dev.sebb.sebtype.core.NativeCore.XK_BackSpace
import dev.sebb.sebtype.core.NativeCore.XK_Return
import dev.sebb.sebtype.core.NativeCore.XK_Tab
import dev.sebb.sebtype.core.NativeState
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
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
import org.futo.inputmethod.latin.InputAttributes
import dev.sebb.sebtype.Incognito
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
import org.futo.inputmethod.latin.utils.ZipFileHelper
import org.futo.inputmethod.latin.utils.toEnumOrNull
import org.futo.inputmethod.v2keyboard.KeyboardLayoutSetV2
import java.io.File
import java.io.IOException
import java.util.Locale
import kotlin.math.max
import kotlin.math.min
import dev.sebb.sebtype.chinese.ChineseLearnedWords
import dev.sebb.sebtype.chinese.ChineseOptions
import dev.sebb.sebtype.chinese.RimeIceBundle
import dev.sebb.sebtype.chinese.RimeIceSetup
import dev.sebb.sebtype.sync.ChineseSync

object ChineseIMESettings {
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

    val FuzzyPinyinSetting = SettingsKey(
        stringPreferencesKey("ChineseIME_fuzzy_pinyin"),
        ""
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

    // Rime runs in core/ (NativeCore), shared with the background setup (RimeIceSetup).
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
        @JvmStatic
        private val StrokeTransformation = mapOf(
            'h' to '⼀',
            's' to '⼁',
            'p' to '⼃',
            'n' to '⼂',
            'z' to '⼄',
        )

        /** Rime's user data (learned words, settings patches), in private storage (#32) */
        @JvmStatic
        fun getRimeDir(context: Context): File = File(context.filesDir, "rime").also {
            if(!it.exists()) moveFromExternalStorage(context, it)
        }

        /** The bundled data ([RimeIceBundle]), installed again after every update: kept out of backups */
        @JvmStatic
        fun getShared(context: Context) = File(context.noBackupFilesDir, "rime/shared")

        @JvmStatic
        fun getUser(context: Context) = File(getRimeDir(context), "user")

        /**
         * SebType (#32): Rime's data used to be in external storage, which other apps and tools can read.
         * Its user dir moves to [dir] once; the shared data stays behind, as the bundle installs it again.
         */
        @Synchronized
        private fun moveFromExternalStorage(context: Context, dir: File) {
            if(dir.exists()) return
            // Creates the external files dir if missing: removed again below while empty.
            val external = context.getExternalFilesDir(null)
            val old = external?.let { File(it, "rime") }
            val oldUser = old?.let { File(it, "user") }
            if(oldUser?.isDirectory == true) {
                // Copied (external storage is another file system) into a temporary dir renamed at the
                // end, so an interrupted move is redone from the start.
                val moving = File(context.filesDir, "rime.moving").apply { deleteRecursively() }
                oldUser.copyRecursively(File(moving, "user"))
                if(!moving.renameTo(dir)) throw IOException("Can't move Rime's data to $dir")
            } else {
                dir.mkdirs()
            }
            old?.deleteRecursively()
            external?.delete()
        }

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

    /** A key Rime didn't take ([sym]; [codePoint] for a character), with [preedit] what was typed. */
    private fun passBy(sym: Int, codePoint: Int, preedit: String) {
        when (sym) {
            XK_BackSpace -> sendDownUpKeyEvent(KeyEvent.KEYCODE_DEL, 0)
            XK_Tab       -> sendDownUpKeyEvent(KeyEvent.KEYCODE_TAB, 0)
            XK_Return    -> sendDownUpKeyEvent(KeyEvent.KEYCODE_ENTER, 0)
            else -> {
                if (!ready || preedit.isEmpty() || editingState.active) {
                    connect?.commitText(String(Character.toChars(codePoint)), 1)
                } else {
                    // Commits what is typed, then the key again.
                    show(NativeCore.flush())
                    val state = NativeCore.key(sym, 0)
                    show(state)
                    if (!state.taken) passBy(sym, codePoint, state.preedit)
                }
            }
        }
    }

    // What the preedit and the bar last showed of Rime's: each is drawn again only when it changes.
    private var shownPreedit = ""
    private var shownCandidates: List<Pair<String, String>> = emptyList()

    /** Shows what a call to Rime did: its commit, then its preedit and candidates. */
    private fun show(state: NativeState) {
        if (state.commit.isNotEmpty()) {
            connect?.commitText(state.commit, 1)
            if(!noLearning) ChineseSync.onChineseCommit(helper.context)
        }
        showPreedit(state.preedit)
        showCandidates(state.candidates.indices.map { state.candidates[it] to state.comments[it] })
    }

    private fun showPreedit(ped: String) {
        if(ped == shownPreedit) return
        shownPreedit = ped
        val notEditing = editingState == EditingState.NotEditing
        if(ped.isEmpty() && notEditing) { rawInput.clear() }

        helper.updateUiInputState(ped.isEmpty() && notEditing)
        helper.setPreedit(FloatingPreEdit.build(ped, this, currentTransformation, rawInput.text))
    }

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

    override fun onUpdateEdit(string: String) {
        if(!ready) return
        val converted = safeguardInputStringForSimulation(string)
        rawInput.replace(converted)
        show(NativeCore.type(converted))
    }

    override fun onFinishEdit(string: String, candidateWord: String?, candidateIndex: Int?) {
        if(!editingState.active) return
        editingState = EditingState.Finishing

        if(ready) {
            val converted = safeguardInputStringForSimulation(string)
            rawInput.replace(converted)
            val typed = NativeCore.type(converted)
            editingState = EditingState.NotEditing
            // The candidate picked in the floating preedit, if it is still there
            show(if(candidateIndex != null && typed.candidates.getOrNull(candidateIndex) == candidateWord)
                NativeCore.selectCandidate(candidateIndex) else typed)
        }
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

    private fun showCandidates(cdd: List<Pair<String, String>>) {
        if(cdd == shownCandidates) return
        shownCandidates = cdd

        val suggestWordList = cdd.mapIndexed { index, (text, comment) -> SuggestedWordInfo(
            text,
            "",
            Int.MAX_VALUE - index,
            1,
            null,
            SuggestedWordInfo.NOT_AN_INDEX,
            SuggestedWordInfo.NOT_A_CONFIDENCE,
            index,
            comment
        ) }.let { ArrayList(it) }

        // Don't flicker an empty suggest bar when editing
        if(editingState != EditingState.NotEditing && suggestWordList.isEmpty()) {
            return
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
    }

    override fun onCreate() {
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

    // SebType (#30): password and PIN fields, and fields that ask for no suggestions, get plain letters:
    // Rime never sees the keys, so there is no preedit, no candidates and nothing to learn. Private
    // (no personalised learning), URL and email fields keep pinyin but learn nothing.
    private var plainField = false
    private var noLearning = false

    override fun onStartInput() {
        // From the field itself: the settings still hold the previous field's attributes at this point.
        val attrs = InputAttributes(helper.getCurrentEditorInfo(), false, helper.context.packageName)
        plainField = attrs.mIsPasswordField || !attrs.mShouldShowSuggestions
        noLearning = attrs.mNoLearning || attrs.mIsUriField || attrs.mIsEmailField || Incognito.toggledOn(helper.context)
        SebTypeConf.ensure(helper.context)
        NativeCore.selectLanguage(CHINESE)
        NativeCore.setField(if(plainField) NativeCore.FIELD_PLAIN else NativeCore.FIELD_TEXT, !noLearning)
        RimeIceSetup.setInUse(helper.context, true)
        showSetupState(RimeIceSetup.state.value)
        updateConfig()
    }

    private var prevConfiguration: RimeIceSetup.Configuration? = null

    // SebType (#36): the menu's 简/繁 switch. It saves the choice in sebtype.conf, and core/ turns rime-ice's
    // traditionalization option on or off at once, with no new deploy. The option converts only what Rime
    // outputs, so learned words stay the same in both.
    private val traditional = mutableStateOf(false)

    override fun getMenuSwitch() = MenuSwitch("简体", "繁體", traditional.value) { on ->
        traditional.value = on
        coroScope.launch(Dispatchers.IO) {
            SebTypeConf.set(helper.context, SebTypeConf.Option.Traditional, on)
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
                val schema = RimeIceSetup.schemaFor(layoutHint) ?: return@launch
                traditional.value = !RimeIceSetup.isSimplifiedChinese(helper.context)

                val config = RimeIceSetup.Configuration(
                    schema,
                    learning = settings.isPersonalizationEnabled,
                    fuzzyMode = ChineseIMESettings.FuzzyPinyinModes.fromCommaString(
                        helper.context.getSetting(ChineseIMESettings.FuzzyPinyinSetting)
                    )
                )
                if(config == prevConfiguration && ready) return@launch

                prevConfiguration = null
                // Joins a setup already running in the background (setup screen, app update).
                if(RimeIceSetup.ensure(helper.context, config)) {
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
        rawInput.clear()
        show(NativeCore.clear())
    }

    override fun onFinishSlidingInput() {
    }

    private fun interruptInput(text: CharSequence? = null) {
        if(ready) {
            rawInput.clear()
            show(NativeCore.clear())
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
                val codePoint = when (event.mKeyCode) {
                    Constants.CODE_DELETE -> '\b'.code
                    Event.NOT_A_KEY_CODE -> ChineseOptions.punctuation(helper.context, event.mCodePoint)
                    else -> return
                }
                val sym = when (codePoint) {
                    '\b'.code -> XK_BackSpace
                    '\t'.code -> XK_Tab
                    '\n'.code, '\r'.code -> XK_Return
                    else -> NativeCore.charSym(codePoint)
                }

                if(!ready || plainField || editingState.active) {
                    passBy(sym, codePoint, shownPreedit)
                } else {
                    // Only update outside editing state. We cannot update inside editing state,
                    // because the cursor position is unknown and we assume it's always at the end
                    if(sym == XK_BackSpace) {
                        rawInput.backspace()
                    } else if(sym == XK_Return || sym == ' '.code) {
                        rawInput.clear()
                    } else if(event.mKeyCode == Event.NOT_A_KEY_CODE) {
                        rawInput.append(event.mCodePoint)
                    }

                    val state = NativeCore.key(sym, 0)
                    show(state)
                    if(!state.taken) passBy(sym, codePoint, state.preedit)
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
                    show(NativeCore.selectCandidate(suggestion.mCandidateIndex))
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
                        coroScope.launch(Dispatchers.IO) { NativeCore.deploy(CHINESE) }
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
        run {
            val preedit = shownPreedit
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
                    return
                }
            }
            rawInput.clear()
            if(ready) show(NativeCore.clear())
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
            // Keeps the user's own words and Rime's deployed build (#41)
            ChineseLearnedWords.forget(helper.context)
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
        get() = "configuration=${prevConfiguration}\nlayoutHint=${layoutHint}\nlocale=${Settings.getInstance().current.mLocale}\nisSimplified=${RimeIceSetup.isSimplifiedChinese(helper.context)}\nrawInput=${rawInput.text}"
}
