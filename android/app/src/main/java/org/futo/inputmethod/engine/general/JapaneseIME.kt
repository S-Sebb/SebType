package org.futo.inputmethod.engine.general

import android.content.Context
import android.content.res.Configuration
import android.icu.text.BreakIterator
import android.os.SystemClock
import android.text.InputType
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.TextUtils
import android.text.style.BackgroundColorSpan
import android.text.style.UnderlineSpan
import android.util.Log
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import androidx.compose.runtime.mutableStateOf
import androidx.datastore.preferences.core.booleanPreferencesKey
import dev.sebb.sebtype.SebTypeConf
import dev.sebb.sebtype.core.NativeCore
import dev.sebb.sebtype.core.NativeCore.JAPANESE
import dev.sebb.sebtype.core.NativeState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.futo.inputmethod.engine.ENGINE_IDLE_MS
import org.futo.inputmethod.engine.ExpandableSuggestionBarConfiguration
import org.futo.inputmethod.engine.GlobalIMEMessage
import org.futo.inputmethod.engine.IMEHelper
import org.futo.inputmethod.engine.IMEInterface
import org.futo.inputmethod.engine.IMEMessage
import org.futo.inputmethod.engine.ModeChip
import org.futo.inputmethod.engine.StateHint
import org.futo.inputmethod.engine.general.mozc.SelectionTracker
import org.futo.inputmethod.event.Event
import org.futo.inputmethod.keyboard.KeyboardId
import org.futo.inputmethod.keyboard.internal.KeyboardLayoutKind
import org.futo.inputmethod.latin.BuildConfig
import org.futo.inputmethod.latin.InputConnectionUtil
import org.futo.inputmethod.latin.Subtypes
import org.futo.inputmethod.latin.SubtypesSetting
import org.futo.inputmethod.latin.SuggestedWords
import org.futo.inputmethod.latin.SuggestedWords.SuggestedWordInfo
import org.futo.inputmethod.latin.SuggestionBlacklist
import org.futo.inputmethod.latin.common.Constants
import org.futo.inputmethod.latin.common.InputPointers
import org.futo.inputmethod.latin.common.StringUtils
import org.futo.inputmethod.latin.localeFromString
import org.futo.inputmethod.latin.settings.Settings
import org.futo.inputmethod.latin.uix.FileKind
import org.futo.inputmethod.latin.uix.ResourceHelper
import org.futo.inputmethod.latin.uix.SettingsKey
import org.futo.inputmethod.latin.uix.UserDictionaryIO
import dev.sebb.sebtype.Incognito
import org.futo.inputmethod.latin.uix.actions.ArrowLeftAction
import org.futo.inputmethod.latin.uix.actions.ArrowRightAction
import org.futo.inputmethod.latin.uix.actions.UndoAction
import org.futo.inputmethod.latin.uix.actions.keyCode
import org.futo.inputmethod.latin.uix.getImportedUserDictFilesForLocale
import org.futo.inputmethod.latin.uix.getSetting
import org.futo.inputmethod.latin.uix.isDirectBootUnlocked
import org.futo.inputmethod.latin.uix.settings.pages.pdict.decodeJapanesePersonalWord
import org.futo.inputmethod.latin.utils.Dictionaries
import org.futo.inputmethod.latin.utils.InputTypeUtils
import org.futo.inputmethod.latin.utils.JniUtils
import org.futo.inputmethod.v2keyboard.KeyboardLayoutSetV2
import org.mozc.android.inputmethod.japanese.protobuf.ProtoUserDictionaryStorage
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.Locale

// Focused segment's attribute.
private val SPAN_CONVERT_HIGHLIGHT = BackgroundColorSpan(0x66EF3566)

// Background color span for non-focused conversion segment.
// We don't create a static CharacterStyle instance since there are multiple segments at the
// same
// time. Otherwise, segments except for the last one cannot have style.
private const val CONVERT_NORMAL_COLOR = 0x19EF3566

// Cursor position.
// Note that InputConnection seems not to be able to show cursor. This is a workaround.
private val SPAN_BEFORE_CURSOR = BackgroundColorSpan(0x664DB6AC)

// Background color span for partial conversion.
private val SPAN_PARTIAL_SUGGESTION_COLOR = BackgroundColorSpan(0x194DB6AC)

// Underline.
private val SPAN_UNDERLINE = UnderlineSpan()

// The field's kind, as Mozc's Android client told Mozc (MozcUtil.isPasswordField and getInputFieldType).
internal fun fieldOf(attribute: EditorInfo): Int {
    val inputType = attribute.inputType
    val inputClass = inputType and InputType.TYPE_MASK_CLASS
    val variation = inputType and InputType.TYPE_MASK_VARIATION
    return when {
        inputClass == InputType.TYPE_CLASS_TEXT && (variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD ||
            variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
            variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD) -> NativeCore.FIELD_PASSWORD
        inputClass == InputType.TYPE_CLASS_PHONE -> NativeCore.FIELD_PHONE
        inputClass == InputType.TYPE_CLASS_NUMBER -> NativeCore.FIELD_NUMBER
        else -> NativeCore.FIELD_TEXT
    }
}

fun mozcUserProfileDir(context: Context) = File(context.applicationInfo.dataDir, ".mozc")

/** Tells core/ where Mozc's profile and dictionary are; Mozc loads them when 日本語 next starts. */
fun setMozcData(context: Context) {
    SebTypeConf.ensure(context)

    // Ensure the user profile directory exists.
    val userProfileDirectory = mozcUserProfileDir(context)
    if (!userProfileDirectory.exists()) {
        // No profile directory is found. Create the one.
        if (!userProfileDirectory.mkdirs()) {
            // Failed to create a directory. The mozc conversion engine will be able to run
            // even in this case, but no persistent data (e.g. user history, user dictionary)
            // will be stored, so some fuctions using them won't work well.
            Log.e(TAG, "Failed to create user profile directory: " + userProfileDirectory.absolutePath)
        }
    }

    val dictFile = ResourceHelper.findFileForKind(
        context,
        Locale.forLanguageTag("ja-JP"),
        FileKind.Dictionary
    ) ?: run {
        // Locate the exact locale in case it's something unexpected (different country, script, etc)
        val subtypes = context.getSetting(SubtypesSetting)
        subtypes.map {
            Subtypes.getLocale(Subtypes.convertToSubtype(it))
        }.firstNotNullOfOrNull {
            if(it.language.lowercase() == "ja") {
                ResourceHelper.findFileForKind(
                    context,
                    it,
                    FileKind.Dictionary
                )
            } else null
        }
    }

    val fallbackFile = if(dictFile != null) null else run {
        Dictionaries.getDictionaryIfExists(context, Locale("ja"), Dictionaries.DictionaryKind.Mozc)
    }

    if(BuildConfig.DEBUG) {
        Log.d(TAG, "userProfileDirectory path = ${userProfileDirectory.absolutePath}")
        Log.d(TAG, "dictFile path = ${dictFile?.absolutePath} OR $fallbackFile")
    }

    when {
        dictFile != null -> NativeCore.setMozcData(userProfileDirectory.absolutePath, dictFile.absolutePath, 0, 0)
        fallbackFile != null -> NativeCore.setMozcData(
            userProfileDirectory.absolutePath,
            fallbackFile.mFilename,
            fallbackFile.mOffset,
            fallbackFile.mLength
        )
        else -> NativeCore.setMozcData(userProfileDirectory.absolutePath, "", 0, 0)
    }
}

private const val MOZC_DICT_NAME = "FUTO_UserDict"
private fun sha256(text: String) =
    MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }
fun refreshMozcDictionaries(context: Context, onlyIfChanged: Boolean = false) {
    val importedDictionaries = getImportedUserDictFilesForLocale(context, Locale.JAPANESE)
    val words = UserDictionaryIO(context).get()
        .filter { it.locale?.let { localeFromString(it) }?.language == "ja" }
        .mapNotNull { decodeJapanesePersonalWord(it) }

    // SebType (#97): Mozc keeps the user dictionaries it was given, so its start rewrites them only when
    // the imported dictionaries or the personal words changed. A missing stamp means nothing was given yet.
    val stamp = File(mozcUserProfileDir(context), "sebtype-user-dictionaries.sha256")
    val source = sha256(
        (importedDictionaries.map { (file, _) -> "${file.name}\t${file.length()}\t${file.lastModified()}" } +
            words.map { "${it.furigana}\t${it.output}\t${it.pos.id}" }).joinToString("\n")
    )
    if(onlyIfChanged && source == (stamp.takeIf { it.exists() }?.readText() ?: sha256(""))) return

    // SebType (#186): Mozc takes no user dictionary commands any more, so the keyboard writes Mozc's
    // user_dictionary.db itself, one dictionary per imported file and one for the personal words, and
    // has Mozc reload it.
    val storage = ProtoUserDictionaryStorage.UserDictionaryStorage.newBuilder()
    importedDictionaries.forEach { (file, _) ->
        storage.addDictionaries(
            ProtoUserDictionaryStorage.UserDictionary.parseFrom(NativeCore.importMozcUserDictionary(file.readBytes()))
                .toBuilder().setId(storage.dictionariesCount + 1L).setName(file.nameWithoutExtension)
        )
    }
    storage.addDictionaries(
        ProtoUserDictionaryStorage.UserDictionary.newBuilder()
            .setId(storage.dictionariesCount + 1L)
            .setName(MOZC_DICT_NAME)
            .addAllEntries(words.map {
                ProtoUserDictionaryStorage.UserDictionary.Entry.newBuilder()
                    .setKey(it.furigana).setValue(it.output).setPos(it.pos.id).build()
            })
    )
    val db = File(mozcUserProfileDir(context), "user_dictionary.db")
    val written = File(db.path + ".new")
    written.writeBytes(storage.build().toByteArray())
    if(!written.renameTo(db)) throw IOException("Can't write ${db.path}")
    // A Mozc that isn't running reads them when it starts.
    if(NativeCore.running(JAPANESE)) NativeCore.deploy(JAPANESE)
    stamp.writeText(source)
}

private const val SUGGESTION_ID_INVERSION = 10000
private const val TAG = "JapaneseIME"
class JapaneseIME(val helper: IMEHelper) : IMEInterface {
    val selectionTracker = SelectionTracker()

    var layoutHint: String? = null
    var configId: KeyboardId? = null
    // The keys on screen, as core/ tells Mozc (NativeCore.KEYS_*)
    private var keys = NativeCore.KEYS_KANA

    // SebType (#38): the bar's あ ⇄ ア chip turns hiragana composition into full-width katakana.
    // Katakana forms also come as candidates in あ. Each new field starts in あ.
    private val katakana = mutableStateOf(false)

    override fun getModeChip() = ModeChip(listOf("あ", "ア"), if(katakana.value) 1 else 0) {
        setKatakana(!katakana.value)
    }

    private fun setKatakana(on: Boolean) {
        katakana.value = on
        helper.keyboardSwitcher.mainKeyboardView?.setSpacebarMode(if(on) "ア" else null)
        NativeCore.setAlternate(on)
    }

    // SebType's Japanese layout is QWERTY: romaji on its letters, the letters themselves on its second
    // page, and the symbols and numbers.
    private fun getCurrentKeys(): Int {
        val id = helper.keyboardSwitcher.keyboard?.mId
        configId = id
        return when(id?.mElement?.kind) {
            KeyboardLayoutKind.Symbols, KeyboardLayoutKind.Number, KeyboardLayoutKind.NumberBasic,
            KeyboardLayoutKind.Phone -> NativeCore.KEYS_SYMBOLS
            KeyboardLayoutKind.Alphabet1, KeyboardLayoutKind.Alphabet2, KeyboardLayoutKind.Alphabet3 -> NativeCore.KEYS_LETTERS
            else -> NativeCore.KEYS_KANA
        }
    }

    // Mozc's config (learning, the space's width) comes from the field and sebtype.conf: core/ sets it.
    private fun updateConfig(resetSelectionTracker: Boolean = true) {
        keys = getCurrentKeys()
        NativeCore.setKeys(keys, helper.context.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE)
        if(resetSelectionTracker) selectionTracker.onConfigurationChanged()
    }

    internal fun mozcInit() {
        idleUnload?.cancel()
        unloaded = false
        setMozcData(helper.context)
        // Loaded afresh, as Mozc's Android client did: the dictionary file may have been replaced.
        NativeCore.stop(JAPANESE)
        NativeCore.start(JAPANESE)

        updateConfig()

        if(helper.context.isDirectBootUnlocked) {
            NativeCore.save(JAPANESE)
            refreshMozcDictionaries(helper.context, onlyIfChanged = true)
        }
    }

    override fun onCreate() {
        mozcInit()
        helper.lifecycleScope.launch {
            GlobalIMEMessage.collect { message ->
                when(message) {
                    IMEMessage.ReloadResources -> withContext(Dispatchers.Main) {
                        mozcInit()
                    }
                    IMEMessage.ReloadPersonalDict -> withContext(Dispatchers.Main) {
                        refreshMozcDictionaries(helper.context)
                    }
                    else -> {}
                }
            }
        }

        blacklist.init()
    }

    // SebType (#56): Mozc's engine (its dictionary and caches) unloads ENGINE_IDLE_MS after 日 was left,
    // and the next 日 field loads it again; finishing input synced the user data.
    private var idleUnload: Job? = null
    private var unloaded = false

    override fun onLanguageLeft() {
        idleUnload?.cancel()
        idleUnload = helper.lifecycleScope.launch {
            delay(ENGINE_IDLE_MS)
            NativeCore.stop(JAPANESE)
            unloaded = true
            Log.w(TAG, "Mozc unloaded after ${ENGINE_IDLE_MS / 1000} s in another language")
            withContext(Dispatchers.Default) { JniUtils.releaseFreedMemory() }
        }
    }

    override fun onDestroy() {
        idleUnload?.cancel()
        NativeCore.save(JAPANESE)
    }

    override fun onDeviceUnlocked() {
        mozcInit()
    }

    // Similar to RichInputConnection.tryExtractCursorPosition
    private fun initSelectionTracker() {
        var selStart = -1
        var selEnd = -1

        helper.getCurrentInputConnection()?.let { ic ->
            val selection = InputConnectionUtil.extractSelection(ic)
            selStart = selection.first
            selEnd = selection.second
        }

        helper.getCurrentEditorInfo()?.let { ei ->
            if(selStart < 0 || selEnd < 0) {
                selStart = ei.initialSelStart
                selEnd = ei.initialSelEnd
            }
        }

        // Any non -1 negative value is invalid, safeguard against it
        if(selStart < 0 || selEnd < 0) {
            selStart = -1
            selEnd = -1
        }

        selectionTracker.onStartInput(selStart, selEnd, false)
    }

    override fun onStartInput() {
        idleUnload?.cancel()
        if(unloaded) {
            val t0 = SystemClock.elapsedRealtime()
            mozcInit()
            Log.w(TAG, "Mozc loaded again in ${SystemClock.elapsedRealtime() - t0} ms")
        }
        NativeCore.selectLanguage(JAPANESE)
        // From the field itself: at its start the settings still hold the previous field's attributes.
        // SebType (#31, #158): while incognito Mozc still suggests from its history but adds nothing to it.
        val incognito = Incognito.inField(helper.context, helper.getCurrentEditorInfo())
        NativeCore.setField(
            helper.getCurrentEditorInfo()?.let { fieldOf(it) } ?: NativeCore.FIELD_TEXT,
            !incognito && Settings.getInstance().current.isPersonalizationEnabled
        )
        NativeCore.clear()
        setNeutralSuggestionStrip()
        katakana.value = false
        helper.keyboardSwitcher.mainKeyboardView?.setSpacebarMode(null)
        NativeCore.setAlternate(false)
        updateConfig()
        initSelectionTracker()
    }

    override fun onOrientationChanged() {
        updateConfig()
    }

    override fun onFinishInput() {
        helper.keyboardSwitcher.mainKeyboardView?.setSpacebarMode(null)
        NativeCore.save(JAPANESE)
        selectionTracker.onFinishInput()
        resetContextAndCommitText()
    }

    override fun onUpdateSelection(
        oldSelStart: Int,
        oldSelEnd: Int,
        newSelStart: Int,
        newSelEnd: Int,
        composingSpanStart: Int,
        composingSpanEnd: Int
    ) {
        val updateStatus = selectionTracker.onUpdateSelection(
            oldSelStart, oldSelEnd,
            newSelStart, newSelEnd,
            composingSpanStart, composingSpanEnd,
            false
        )

        if(BuildConfig.DEBUG) Log.d(TAG, "Update selection from $oldSelStart:$oldSelEnd to $newSelStart:$newSelEnd [$composingSpanStart:$composingSpanEnd]. Status $updateStatus")

        when(updateStatus) {
            SelectionTracker.DO_NOTHING -> {}
            SelectionTracker.RESET_CONTEXT -> {
                if(BuildConfig.DEBUG) Log.d(TAG, "Asked to reset context.")
                NativeCore.clear()
                helper.getCurrentInputConnection()?.finishComposingText()
                setNeutralSuggestionStrip()
            }

            else -> {
                if(updateStatus < 0) throw IllegalStateException("Invalid updateStatus $updateStatus")
                render(NativeCore.moveCursor(updateStatus), null)
            }
        }
    }

    override fun isGestureHandlingAvailable(): Boolean {
        return false
    }

    override fun getStateHint(imeHint: String?): StateHint = if(imeHint == "12key") StateHint(true, true) else StateHint()

    private fun maybeProcessDelete(keyCode: Int): Boolean {
        if(keyCode != Constants.CODE_DELETE) return false

        // If we have a selection, send DEL event to delete the selection
        if(selectionTracker.lastSelectionEnd != selectionTracker.lastSelectionStart) {
            sendDownUpKeyEvent(
                KeyEvent.KEYCODE_DEL,
                0
            )
        } else {
            val text = helper.getCurrentInputConnection()?.getTextBeforeCursor(8, 0).toString()
            val bi = BreakIterator.getCharacterInstance()

            bi.setText(text)
            val end = bi.last()
            val prev = bi.previous()

            if(prev == -1 || end == -1) {
                helper.getCurrentInputConnection()?.deleteSurroundingText(1, 0)
            } else {
                helper.getCurrentInputConnection()?.deleteSurroundingText(end - prev, 0)
            }
        }
        return true
    }

    private fun resetContextAndCommitText(text: CharSequence? = null) {
        NativeCore.clear()

        val ic = helper.getCurrentInputConnection() ?: return
        ic.finishComposingText()

        if(text != null) ic.commitText(text, 1)
    }

    private fun sendCodePoint(codePoint: Int): Unit = when(codePoint) {
        Constants.CODE_ENTER -> {
            // TODO: Code duplication between here and InputLogic.handleNonFunctionalEvent
            val ei = helper.getCurrentEditorInfo() ?: return
            val ic = helper.getCurrentInputConnection() ?: return
            val imeOptionsActionId = InputTypeUtils.getImeOptionsActionIdFromEditorInfo(ei)

            val isCustomAction =
                InputTypeUtils.IME_ACTION_CUSTOM_LABEL == imeOptionsActionId
            val isEditorAction =
                EditorInfo.IME_ACTION_NONE != imeOptionsActionId

            if(isCustomAction) {
                ic.performEditorAction(ei.actionId)
            } else if(isEditorAction) {
                ic.performEditorAction(imeOptionsActionId)
            } else {
                resetContextAndCommitText(StringUtils.newSingleCodePointString(Constants.CODE_ENTER))
            }

            Unit
        }

        else -> {
            resetContextAndCommitText(StringUtils.newSingleCodePointString(codePoint))
        }
    }

    /** Handles a key Mozc didn't take: [keyCode] a key or action, or else [codePoint] a character. */
    private fun sendKey(keyCode: Int, codePoint: Int) {
        if(keyCode == Event.NOT_A_KEY_CODE) {
            sendCodePoint(codePoint)
            return
        }
        // Some keys have a potential to be consumed from mozc client.
        if (maybeProcessDelete(keyCode)) return
        if (maybeHandleAction(keyCode)) return
        sendDownUpKeyEvent(keyCode, 0)
    }

    // TODO: Code duplication between InputLogic and here
    fun sendDownUpKeyEvent(keyCode: Int, metaState: Int) {
        val eventTime = SystemClock.uptimeMillis()
        helper.getCurrentInputConnection()?.sendKeyEvent(
            KeyEvent(
                eventTime, eventTime,
                KeyEvent.ACTION_DOWN, keyCode, 0, metaState, KeyCharacterMap.VIRTUAL_KEYBOARD, 0,
                KeyEvent.FLAG_SOFT_KEYBOARD or KeyEvent.FLAG_KEEP_TOUCH_MODE
            )
        )
        helper.getCurrentInputConnection()?.sendKeyEvent(
            KeyEvent(
                SystemClock.uptimeMillis(), eventTime,
                KeyEvent.ACTION_UP, keyCode, 0, metaState, KeyCharacterMap.VIRTUAL_KEYBOARD, 0,
                KeyEvent.FLAG_SOFT_KEYBOARD or KeyEvent.FLAG_KEEP_TOUCH_MODE
            )
        )
    }


    private fun maybeCommitText(state: NativeState, inputConnection: InputConnection) {
        if (state.commit.isEmpty()) return
        // Mozc's cursor after the commit: at its end, or (a pair of brackets) at its start
        val position = if (state.commitCursor != 0) 0 else 1
        if (!inputConnection.commitText(state.commit, position)) {
            Log.e(TAG, "Failed to commit text.")
        }
    }

    private var hasPreedit = false

    /** Shows what a call to Mozc did in the field and the bar; [key] is the key's code and code point. */
    private fun render(state: NativeState, key: Pair<Int, Int>?) {
        val inputConnection = helper.getCurrentInputConnection() ?: return
        if(!state.taken) {
            maybeCommitText(state, inputConnection)
            key?.let { (keyCode, codePoint) -> sendKey(keyCode, codePoint) }
            showCandidates(state)
            return
        }

        // Here the key is consumed by the Mozc server.
        val deleted = state.deleteBefore > 0 || state.deleteAfter > 0
        val preedit = state.preedit
        inputConnection.beginBatchEdit()
        try {
            if (deleted && !inputConnection.deleteSurroundingText(state.deleteBefore, state.deleteAfter)) {
                Log.e(TAG, "Failed to delete surrounding text.")
            }
            maybeCommitText(state, inputConnection)
            setComposingText(state, inputConnection)
            maybeSetSelection(state, inputConnection)
            selectionTracker.onRender(
                if (deleted) -state.deleteBefore else null,
                state.commit.ifEmpty { null },
                preedit.ifEmpty { null },
                state.cursor,
            )
        } finally {
            inputConnection.endBatchEdit()
        }

        hasPreedit = preedit.isNotEmpty()
        helper.keyboardSwitcher.requestUpdatingShiftState(getCurrentAutoCapsState())
        showCandidates(state)
    }

    // We use the "shift" alphabet state to show the language switch key
    override fun getCurrentAutoCapsState() = when {
        !hasPreedit && layoutHint == "12key" -> TextUtils.CAP_MODE_CHARACTERS
        else -> Constants.TextUtils.CAP_MODE_OFF
    }

    private fun setComposingText(state: NativeState, inputConnection: InputConnection) {
        helper.updateUiInputState(state.preedit.isEmpty())

        if (state.preedit.isEmpty()) {
            // If preedit field is empty, we should clear composing text in the InputConnection
            // because Mozc server asks us to do so.
            if (!inputConnection.setComposingText("", 0)) {
                Log.e(TAG, "Failed to set composing text.")
            }
            return
        }

        // Builds preedit expression.
        val builder = SpannableStringBuilder()
        for (segment in state.segments) {
            builder.append(segment)
        }

        // Set underline for all the preedit text.
        builder.setSpan(SPAN_UNDERLINE, 0, builder.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)

        // Draw cursor if in composition mode.
        val cursor = state.cursor
        val spanFlags = Spanned.SPAN_EXCLUSIVE_EXCLUSIVE or Spanned.SPAN_COMPOSING
        // Converting: Mozc highlights the segment being converted.
        if (state.highlighted.any { it }) {
            var offsetInString = 0
            state.segments.forEachIndexed { i, segment ->
                val length = segment.length
                builder.setSpan(
                    if (state.highlighted[i]) SPAN_CONVERT_HIGHLIGHT
                    else BackgroundColorSpan(CONVERT_NORMAL_COLOR),
                    offsetInString,
                    offsetInString + length,
                    spanFlags,
                )
                offsetInString += length
            }
        } else {
            // We cannot show system cursor inside preedit here.
            // Instead we change text style before the preedit's cursor.
            if (cursor != builder.length) {
                builder.setSpan(
                    SPAN_PARTIAL_SUGGESTION_COLOR,
                    cursor,
                    builder.length,
                    spanFlags,
                )
            }
            if (cursor > 0) {
                builder.setSpan(SPAN_BEFORE_CURSOR, 0, cursor, spanFlags)
            }
        }

        // System cursor will be moved to the tail of preedit.
        // It triggers onUpdateSelection again.
        val cursorPosition = if (cursor > 0) 1 else 0
        if (!inputConnection.setComposingText(builder, cursorPosition)) {
            Log.e(TAG, "Failed to set composing text.")
        }
    }

    private fun maybeSetSelection(state: NativeState, inputConnection: InputConnection) {
        val preedit = state.preedit
        if (preedit.isEmpty()) return
        val cursor = state.cursor
        if (cursor == 0 || cursor == preedit.length) {
            // The cursor is at the beginning/ending of the preedit. So we don't anything about the
            // caret setting.
            return
        }
        val caretPosition = selectionTracker.preeditStartPosition - state.deleteBefore + state.commit.length + cursor
        if (!inputConnection.setSelection(caretPosition, caretPosition)) {
            Log.e(TAG, "Failed to set selection.")
        }
    }

    private fun showCandidates(state: NativeState) {
        if(state.candidates.isEmpty()) {
            setNeutralSuggestionStrip()
            return
        }
        val suggestedWordList = state.candidates.mapIndexed { index, word ->
            SuggestedWordInfo(
                word,
                "",
                SUGGESTION_ID_INVERSION - index,
                1,
                null,
                SuggestedWordInfo.NOT_AN_INDEX,
                SuggestedWordInfo.NOT_A_CONFIDENCE,
                index,
                state.comments[index].ifEmpty { null }
            )
        }.let { ArrayList(it) }

        showSuggestionStrip(SuggestedWords(
                suggestedWordList,
                suggestedWordList,
                null,
                false,
                false,
                false,
                0,
                0,
                state.selected.takeIf { it >= 0 }
            )
        )
    }

    // TODO: This rough code pattern appears 3 times in the codebase, probably time to make a util function
    private fun maybeHandleAction(keyCode: Int): Boolean {
        if (keyCode <= Constants.CODE_ACTION_MAX && keyCode >= Constants.CODE_ACTION_0) {
            val actionId: Int = keyCode - Constants.CODE_ACTION_0
            helper.triggerAction(actionId, false)
            return true
        }

        if (keyCode <= Constants.CODE_ALT_ACTION_MAX && keyCode >= Constants.CODE_ALT_ACTION_0) {
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
                if((helper.keyboardSwitcher.keyboard?.mId != configId) && (getCurrentKeys() != keys)) {
                    updateConfig(false)
                }

                val key = event.mKeyCode to event.mCodePoint
                val sym = when (event.mCodePoint) {
                    Constants.CODE_SPACE -> ' '.code
                    Constants.CODE_ENTER -> NativeCore.XK_Return
                    Constants.NOT_A_CODE -> when (event.mKeyCode) {
                        Constants.CODE_SWITCH_ALPHA_SYMBOL -> null
                        Constants.CODE_DELETE -> NativeCore.XK_BackSpace
                        ArrowLeftAction.keyCode -> NativeCore.XK_Left
                        ArrowRightAction.keyCode -> NativeCore.XK_Right
                        UndoAction.keyCode -> {
                            render(NativeCore.undo(), key)
                            return
                        }

                        else -> {
                            if(!maybeHandleAction(event.mKeyCode)) {
                                if(BuildConfig.DEBUG) Log.e(TAG, "Unknown keycode for that event (${event.mCodePoint} ${event.mKeyCode})")
                            }
                            null
                        }
                    }

                    else -> NativeCore.charSym(event.mCodePoint)
                }

                if(sym != null) render(NativeCore.key(sym, 0), key)
            }

            Event.EVENT_TYPE_SUGGESTION_PICKED -> {
                val suggestion = event.mSuggestedWordInfo ?: return
                render(NativeCore.selectCandidate(suggestion.mCandidateIndex), null)
            }

            Event.EVENT_TYPE_SOFTWARE_GENERATED_STRING -> {
                resetContextAndCommitText(event.mText)
            }

            Event.EVENT_TYPE_DOWN_UP_KEYEVENT -> {
                // TODO: Should we be calling this here just to be sure?
                resetContextAndCommitText()

                sendDownUpKeyEvent(event.mKeyCode, event.mX)
            }

            else -> {
                if(BuildConfig.DEBUG) Log.e(TAG, "Unhandled event type ${event.eventType}: $event")
            }
        }
    }

    override fun onStartBatchInput() {

    }

    override fun onUpdateBatchInput(batchPointers: InputPointers?) {

    }

    override fun onEndBatchInput(batchPointers: InputPointers?) {

    }

    override fun onCancelBatchInput() {

    }

    override fun onCancelInput() {

    }

    override fun onFinishSlidingInput() {

    }

    override fun onCustomRequest(requestCode: Int): Boolean {
        return false
    }

    override fun onMovePointer(steps: Int, stepOverWords: Boolean, select: Boolean?) {

    }

    override fun onMoveDeletePointer(steps: Int) {

    }

    override fun onUpWithDeletePointerActive() {

    }

    override fun onUpWithPointerActive() {

    }

    override fun onSwipeLanguage(direction: Int) {

    }

    override fun onMovingCursorLockEvent(canMoveCursor: Boolean) {

    }

    override fun clearUserHistoryDictionaries() {
        if(helper.context.isDirectBootUnlocked) NativeCore.forget(JAPANESE)
    }

    private var prevSuggestions: SuggestedWords? = null
    override fun requestSuggestionRefresh() {
        if(prevSuggestions != null) showSuggestionStrip(prevSuggestions)
    }

    override fun onLayoutUpdated(layout: KeyboardLayoutSetV2) {
        if(layoutHint == layout.mainLayout.imeHint) return
        layoutHint = layout.mainLayout.imeHint
        if(helper.isImeActive(this)) updateConfig(false)
    }

    private val expandableUiCfg = ExpandableSuggestionBarConfiguration(true, true)
    fun setNeutralSuggestionStrip() {
        prevSuggestions = null
        helper.setNeutralSuggestionStrip(expandableUiCfg)
    }

    val blacklist = SuggestionBlacklist(Settings.getInstance(), helper.context, helper.lifecycleScope)
    fun showSuggestionStrip(suggestedWords: SuggestedWords?) {
        // TODO: Blacklisting in Japanese is not properly implemented
        //  1. Filtering out suggestions is easy, just uncomment below
        //  2. During conversion, we need some more complicated logic to skip blacklisted entries mozc has given us, and to recalculate the focused index properly
        val words = suggestedWords//?.let { blacklist.filterBlacklistedSuggestions(it) }
        prevSuggestions = words
        helper.showSuggestionStrip(words, expandableUiCfg)
    }
}
