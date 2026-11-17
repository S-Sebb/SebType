package dev.sebb.sebtype.next

import dev.sebb.sebtype.next.data.PersonalWords
import dev.sebb.sebtype.next.settings.SettingsActivity
import dev.sebb.sebtype.next.data.Prefs
import dev.sebb.sebtype.next.sync.Sync
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.ClipDescription
import android.content.res.Configuration
import android.graphics.Rect
import android.net.Uri
import android.inputmethodservice.InputMethodService
import android.os.Build
import android.os.Bundle
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.BackgroundColorSpan
import android.text.style.UnderlineSpan
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InlineSuggestionsRequest
import android.view.inputmethod.InlineSuggestionsResponse
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.Toast
import androidx.core.view.inputmethod.InputConnectionCompat
import androidx.core.view.inputmethod.InputContentInfoCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import dev.sebb.sebtype.core.NativeCore
import dev.sebb.sebtype.core.NativeCore.CHINESE
import dev.sebb.sebtype.core.NativeCore.ENGLISH
import dev.sebb.sebtype.core.NativeCore.JAPANESE
import dev.sebb.sebtype.core.NativeState
import dev.sebb.sebtype.next.Layout.Code
import kotlin.math.roundToInt

/**
 * SebType's own keyboard (#191, stages 3 and 4). English, 中文 and 日本語 go through core/ ([NativeCore]):
 * each key goes to the engine, and what it returns (text to commit, the composition, candidates) is shown.
 * 中文's pinyin floats above the bar; English's word and 日本語's composition sit in the field. English's
 * next words come from its worker thread ([NativeCore.onEnglishReady]). Every engine call goes to
 * [NativeCore]'s engine thread and its result shows when it comes back, in the order the keys were typed (#241). The action bar, All Actions and
 * their panels (emoji, clipboard) take the keys' place; Keyboard Modes, a row over the keys, moves and resizes them.
 */
class SebTypeIme : InputMethodService(), KeyboardView.Listener, CandidateBar.Listener, ActionRow.Listener,
    ActionsPanel.Listener, EmojiPanel.Listener, ModesPanel.Listener {
    private companion object {
        val ENGLISH_KEYS = setOf(Code.TEXT, Code.SPACE, Code.ENTER, Code.DELETE)
        /** Enough of the text before the cursor to tell where a sentence starts */
        const val SHIFT_CONTEXT = 64
    }

    private enum class Page(val file: String) { LETTERS("letters"), SYMBOLS("symbols"), SYMBOLS2("symbols2"), DIGITS("digits") }

    /** What takes the keys' place */
    private enum class Panel { NONE, ACTIONS, EDIT, EMOJI, CLIPBOARD, MODES }

    private val prefs by lazy { getSharedPreferences("keyboard", MODE_PRIVATE) }
    private val fieldEditor = Editor(this)
    /** What the keys type into: the field, or while a panel's search runs its search field */
    private var editor = fieldEditor
    private val texts by lazy { Texts(this) }
    private val clipboard by lazy { Clipboard(this) { incognito || kind.incognito } }

    private lateinit var root: FrameLayout
    private lateinit var stack: LinearLayout
    private lateinit var panel: ClothPanel
    private lateinit var strip: PreeditStrip
    private lateinit var handle: DragHandle
    private lateinit var actionRow: ActionRow
    private lateinit var bar: CandidateBar
    private lateinit var autofill: AutofillStrip
    private lateinit var keysRow: LinearLayout
    private lateinit var side: SideStrip
    private lateinit var keyboard: KeyboardView
    private lateinit var grid: CandidateGrid
    private lateinit var actions: ActionsPanel
    private lateinit var emoji: EmojiPanel
    private lateinit var clips: ClipboardPanel
    private lateinit var modes: ModesPanel
    private lateinit var search: Search
    private lateinit var searchEditor: Editor
    private lateinit var searchRow: SearchRow
    private lateinit var results: FrameLayout
    private lateinit var barFrame: FrameLayout
    private lateinit var emojiResults: EmojiPanel
    private lateinit var clipResults: ClipboardPanel
    /** The panel (emoji or clipboard) whose search the keys type into, over its results (#281) */
    private var searching: Panel? = null
    private lateinit var content: KeysFrame
    private var views = false

    private var lang = ENGLISH
    private var page = Page.LETTERS
    private var kind = FieldKind.of(null)
    private var katakana = false
    private var shown = Panel.NONE
    private var expanded = false
    private var state: NativeState? = null

    private val incognito get() = prefs.getBoolean("incognito", false)
    /** The action bar stays open, or closed, from one field to the next */
    private var barOpen: Boolean
        get() = prefs.getBoolean("action_bar", false)
        set(value) = prefs.edit().putBoolean("action_bar", value).apply()
    /** Modes are kept per orientation */
    private val orientation get() = if (resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE) "land" else "port"
    private var mode: Mode
        get() = Mode.entries.firstOrNull { it.name == prefs.getString("mode_$orientation", null) } ?: Mode.STANDARD
        set(value) = prefs.edit().putString("mode_$orientation", value.name).apply()
    private var heightScale: Float
        get() = prefs.getFloat("height_$orientation", 1f)
        set(value) = prefs.edit().putFloat("height_$orientation", value).apply()
    private val refreshClip = Runnable { refresh() }
    /** Keyboard Modes shows the height in place of the modes (Resize Keyboard) */
    private var resizing = false
    /** What the last shown result was typing; keys still on the engine thread may have changed it. */
    private val composing get() = state?.preedit?.isNotEmpty() == true
    // Whether the engine has something typed after its last call: read and written on the engine thread
    // only, so a key decides by what the keys before it typed, shown or not.
    private var engineComposing = false
    private var enginePreedit = ""
    private fun NativeState.recorded() = also {
        engineComposing = preedit.isNotEmpty()
        enginePreedit = preedit
    }
    // English: the text before the cursor as the keys sent so far leave it, on the engine thread too, so a
    // letter typed ahead of the engine gets the field's capital by the text it will follow (#241).
    private val engineBefore = StringBuilder()
    // English keys posted and not yet run on the engine thread
    private val englishKeysAhead = java.util.concurrent.atomic.AtomicInteger()
    // English's options and personal words as last sent to core/ (the engine thread's)
    private var englishOptionsSent: Any? = null
    /** The emoji English's word names, and its index in the bar (-1: none) */
    private var emojiShown = ""
    private var emojiAt = -1
    private var keysSent: Int? = null

    override fun onCreate() {
        super.onCreate()
        Engines.configure(this)
        Engines.prepareChinese(this)
        Engines.onChange = { if (views) refresh() }
        // From English's worker: the model's strip for the word being typed (#310), or next words for the
        // text so far. A word's letters are in the field already, so only the strip changes.
        NativeCore.onEnglishReady = Runnable {
            NativeCore.post({ state() }) { if (views && lang == ENGLISH) show(it, applyText = it.preedit.isEmpty()) }
        }
        // A fresh install starts in English (#35).
        lang = prefs.getInt("language", ENGLISH).takeIf { it in Engines.languages() } ?: ENGLISH
        texts.language = lang
        clipboard.onChange = { if (views) refresh() }
        clipboard.start()
    }

    override fun onDestroy() {
        Engines.onChange = null
        NativeCore.onEnglishReady = null
        Engines.saveJapanese()
        Engines.saveEnglish()
        clipboard.stop()
        super.onDestroy()
    }

    override fun onCreateInputView(): View {
        root = FrameLayout(this)
        val popups = PopupLayer(this)
        strip = PreeditStrip(this)
        panel = ClothPanel(this)
        handle = DragHandle(this, texts, ::onDrag) { saveFloating() }
        actionRow = ActionRow(this, texts, this)
        bar = CandidateBar(this, texts, this)
        autofill = AutofillStrip(this)
        keyboard = KeyboardView(this, popups, this)
        side = SideStrip(this, texts, { onSwapSide() }) { onMode(Mode.STANDARD) }
        grid = CandidateGrid(this) { onCandidate(it) }
        actions = ActionsPanel(this, texts, this)
        emoji = EmojiPanel(this, texts, this)
        clips = ClipboardPanel(this, texts, clipboard) { onPasteClip(it) }
        emojiResults = EmojiPanel(this, texts, this, results = true)
        clipResults = ClipboardPanel(this, texts, clipboard, results = true) { onPasteClip(it) }
        searchRow = SearchRow(this, texts) { endSearch() }
        search = Search(root) { onSearchText(it) }
        searchEditor = Editor(this, search.connection)
        results = FrameLayout(this)
        for (v in listOf(emojiResults, clipResults)) results.addView(v, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        modes = ModesPanel(this, texts, this)
        keysRow = LinearLayout(this)
        keysRow.addView(keyboard, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
        keysRow.addView(side, LinearLayout.LayoutParams(0, MATCH_PARENT, 0f))
        content = KeysFrame(this)
        content.addView(keysRow, FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        for (v in listOf(grid, actions, emoji, clips)) content.addView(v, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        barFrame = FrameLayout(this)
        barFrame.addView(bar, FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        barFrame.addView(autofill, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        panel.addView(handle, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        panel.addView(actionRow, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        // A search: its field and results over the bar and the keys, as today's
        panel.addView(searchRow, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        panel.addView(results, LinearLayout.LayoutParams(MATCH_PARENT, 0))
        panel.addView(barFrame, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        panel.addView(modes, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        panel.addView(content, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        stack = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        stack.addView(strip, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        stack.addView(panel, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        root.addView(stack, FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT, android.view.Gravity.BOTTOM))
        root.addView(popups, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        // A resized window, or a keyboard grown taller, moves the floating keyboard to its share of the room.
        for (v in listOf(root, stack)) v.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> placeFloating() }
        // The keys stay clear of the navigation bar the window reaches under. With gesture navigation the
        // keyboard's own bar (back and the keyboard switcher) is taller than the gesture area the
        // navigation-bar inset gives: it is the tappable part.
        ViewCompat.setOnApplyWindowInsetsListener(panel) { v, insets ->
            val bottom = maxOf(insets.getInsets(WindowInsetsCompat.Type.navigationBars()).bottom,
                insets.getInsets(WindowInsetsCompat.Type.tappableElement()).bottom)
            v.setPadding(0, 0, 0, bottom)
            insets
        }
        // The system's back and keyboard-switch buttons under the keys: dark, on the light cloth
        window.window?.let { WindowCompat.getInsetsController(it, it.decorView).isAppearanceLightNavigationBars = true }
        views = true
        return root
    }

    override fun onEvaluateFullscreenMode() = false

    /**
     * The app sees the keyboard from the bar down; the floating pinyin above it lets touches through. A
     * floating keyboard takes no room from the app: only its own touches are its.
     */
    override fun onComputeInsets(outInsets: Insets) {
        super.onComputeInsets(outInsets)
        if (!views || !panel.isShown) return
        val at = IntArray(2).also { panel.getLocationInWindow(it) }
        val top = if (mode == Mode.FLOATING) root.height else at[1]
        outInsets.contentTopInsets = top
        outInsets.visibleTopInsets = top
        outInsets.touchableInsets = Insets.TOUCHABLE_INSETS_REGION
        outInsets.touchableRegion.set(Rect(at[0], at[1], at[0] + panel.width, at[1] + panel.height))
    }

    override fun onStartInput(info: EditorInfo, restarting: Boolean) {
        super.onStartInput(info, restarting)
        // A search ends with its field.
        searching = null
        editor = fieldEditor
        kind = FieldKind.of(info)
        editor.start(info, kind)
        state = null
    }

    override fun onStartInputView(info: EditorInfo, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        if (!restarting) {
            page = Page.LETTERS
            shown = Panel.NONE
            expanded = false
            keyboard.setShift(KeyboardView.Shift.OFF) // Caps Lock ends with its field, as today's does
        }
        enterLanguage()
        keyboard.enter = kind.enter
        keyboard.haptics = Prefs[Prefs.VIBRATE]
        keyboard.sounds = Prefs[Prefs.SOUND]
        keyboard.previews = Prefs[Prefs.KEY_POPUP]
        keyboard.longPressMs = Prefs[Prefs.LONG_PRESS_MS].toLong()
        keyboard.hints = Prefs[Prefs.SHOW_HINTS]
        keyboard.strength = Prefs[Prefs.VIBRATE_STRENGTH]
        englishOptions()
        // Settings' Size and position opened a field to show the keyboard in its Keyboard Modes
        if (prefs.getBoolean("open_modes", false)) {
            prefs.edit().putBoolean("open_modes", false).apply()
            shown = Panel.MODES
        }
        applyMode()
        refresh()
        autoShift()
        Sync.onKeyboardShown()
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        super.onFinishInputView(finishingInput)
        if (views) autofill.clear()
        Engines.inUse(lang, false)
        Engines.saveJapanese()
        Sync.onKeyboardHidden(this)
        Engines.saveEnglish()
    }

    override fun onFinishInput() {
        super.onFinishInput()
        NativeCore.drain() // the results still to come land in this field
        if (composing) NativeCore.post { clear().recorded() }
        editor.finishComposing()
        state = null
        if (views) strip.preedit = ""
    }

    override fun onUpdateSelection(oldSelStart: Int, oldSelEnd: Int, newSelStart: Int, newSelEnd: Int,
                                   candidatesStart: Int, candidatesEnd: Int) {
        super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart, candidatesEnd)
        val external = fieldEditor.selectionChanged(newSelStart, newSelEnd, candidatesStart, candidatesEnd)
        // The keys type into a search: what they typed isn't in the field.
        if (searching != null) return
        // The user moved the cursor away: what was being typed stays as it is in the field.
        if (external && composing) {
            editor.finishComposing()
            NativeCore.post({ clear().recorded() }) { show(it, applyText = false) }
        }
        // English reads the words around the cursor for its corrections and next words, and reopens the word
        // the cursor went into; a move inside the word being typed moves its cursor.
        if (lang == ENGLISH && toEngine) {
            if (external) englishContext()
            else if (editor.movedInside >= 0) {
                val preedit = state?.preedit.orEmpty()
                val chars = preedit.codePointCount(0, minOf(editor.movedInside, preedit.length))
                NativeCore.post({ moveCursor(chars).recorded() }) { show(it, applyText = false) }
            }
        }
        if (views) autoShift()
    }

    /** English reads the text around the cursor again, after it changed other than by its keys. */
    private fun englishContext() {
        val around = editor.around()
        NativeCore.post({
            setContext(around.before, around.after, around.selection)
            engineBefore.setLength(0)
            engineBefore.append(around.before)
            state().recorded().also { if (it.recompose) engineBefore.setLength(maxOf(0, engineBefore.length - it.composeBefore)) }
        }) {
            // Read before a later move or edit: read again, so the engine's word is the field's
            if (editor.unchanged(around)) show(it, around = around) else englishContext()
        }
    }

    /**
     * Settings' English options and the personal dictionary's English words (Android's user dictionary,
     * read on the engine thread): core/ makes its dictionary of them again only when they changed.
     */
    private fun englishOptions() {
        val autocorrect = Prefs[Prefs.AUTOCORRECT]
        val period = Prefs[Prefs.DOUBLE_SPACE_PERIOD]
        val app = applicationContext
        if (Prefs[Prefs.EMOJI_SUGGESTIONS]) Thread { Emoji.forWord(app, "") }.start()
        NativeCore.post {
            val words = PersonalWords.all(app).filter { it.locale == null || it.locale.startsWith("en") }
            val options = Triple(autocorrect, period, words.map { it.word to it.frequency })
            if (options != englishOptionsSent) {
                englishOptionsSent = options
                setEnglishOptions(autocorrect, period, words.map { it.word }.toTypedArray(), words.map { it.frequency }.toIntArray())
            }
        }
    }

    /** The current language for this field: core/'s engine, its field kind, the keys. */
    private fun enterLanguage() {
        val lang = lang
        val field = field()
        val learning = kind.learns && !incognito
        // English reads the words around the cursor for its corrections and next words, and reopens the word
        // the cursor is at.
        val around = editor.around()
        val before = if (lang == ENGLISH && toEngine) around.before else null
        NativeCore.post({
            clear()
            selectLanguage(lang)
            setField(field, learning)
            engineBefore.setLength(0)
            before?.let {
                setContext(it, around.after, around.selection)
                engineBefore.append(it)
            }
            // A new field (or 日本語 again) starts on あ (#38). Mozc starts on あ by itself; asking a stopped
            // one would load it here, ahead of the keys.
            if (lang == JAPANESE && running(JAPANESE)) setAlternate(false)
            // Nothing typed in the new field: the next letter's capital reads no word left from the last one
            engineComposing = false
            enginePreedit = ""
            // The word the cursor is at, reopened: it becomes the composing text
            before?.let { state().takeIf { it.recompose }?.recorded() }
                ?.also { engineBefore.setLength(maxOf(0, engineBefore.length - it.composeBefore)) }
        }) {
            if (it == null) return@post
            if (editor.unchanged(around)) show(it, around = around) else englishContext()
        }
        keysSent = null
        when (lang) {
            CHINESE -> Engines.prepareChinese(this)
            JAPANESE -> {
                katakana = false
                // Words added elsewhere while Mozc was stopped (Android's settings) reach it as it starts (#97).
                PersonalWords.refreshMozc(this, starting = true)
                Engines.prepareJapanese(this)
            }
        }
        Engines.inUse(lang, true)
        state = null
    }

    // --- Keys ---

    /** Keys go to core/ in 中文 (once it is set up) and 日本語, outside number and phone pads. */
    private val toEngine get() = kind.pad == null && when (lang) {
        CHINESE -> Engines.chinese == Engines.Chinese.READY
        else -> true
    }

    /** The field as the language's engine treats it: English corrects nothing in URL and e-mail fields. */
    private fun field() = if (lang == ENGLISH) kind.englishField else kind.field

    override fun onKey(code: Code, text: String, x: Int, y: Int) {
        if (lang == ENGLISH && toEngine && code in ENGLISH_KEYS) english(code, text, x, y)
        else when (code) {
            Code.TEXT -> type(text)
            Code.SPACE -> whileComposing(NativeCore.charSym(' '.code)) { editor.commit(" ") }
            Code.ENTER -> whileComposing(NativeCore.XK_Return) { editor.enter() }
            Code.DELETE -> whileComposing(NativeCore.XK_BackSpace) { editor.deleteBefore() }
            Code.SYMBOLS -> setPage(if (page != Page.SYMBOLS) Page.SYMBOLS else Page.LETTERS)
            Code.SYMBOLS2 -> setPage(Page.SYMBOLS2)
            Code.DIGITS -> setPage(Page.DIGITS)
            Code.LETTERS -> setPage(Page.LETTERS)
            Code.GLOBE -> nextLanguage()
            Code.SHIFT, Code.GAP -> {}
        }
        // By the field as the keys before left it: once their results have shown
        NativeCore.after {
            autoShift()
            if (lang == ENGLISH && toEngine && NativeCore.idle) {
                // All shown: the field is what the engine thread's copy should be (less the word typed).
                val before = editor.textBefore(SHIFT_CONTEXT).dropLast(state?.preedit?.length ?: 0)
                NativeCore.post {
                    engineBefore.setLength(0)
                    engineBefore.append(before)
                }
            }
        }
    }

    private fun type(text: String) {
        if (!toEngine) return commit(text)
        val cp = text.codePointAt(0)
        if (Character.charCount(cp) == text.length && cp < 0x80) {
            NativeCore.post({ key(NativeCore.charSym(cp), 0).recorded() }) {
                show(it)
                if (!it.taken) editor.commit(text)
            }
            return
        }
        // A long-press choice the engine has no key for (？, …): what is typed goes first. In 中文 that is
        // the first candidate, as Rime's own punctuation does.
        val chinese = lang == CHINESE
        NativeCore.post({
            buildList {
                if (engineComposing) {
                    add(if (chinese && state().candidates.isNotEmpty()) selectCandidate(0) else flush())
                    if (last().preedit.isNotEmpty()) add(flush())
                    last().recorded()
                }
            }
        }) { states ->
            states.forEach { show(it) }
            editor.commit(text)
        }
    }

    /** Space, Enter or Delete: to the engine while it has something typed, else [otherwise] in the field. */
    private fun whileComposing(sym: Int, otherwise: () -> Unit) {
        if (!toEngine) return NativeCore.after(otherwise)
        NativeCore.post({ if (engineComposing) key(sym, 0).recorded() else null }) {
            if (it != null) show(it) else otherwise()
        }
    }

    /**
     * English: every key goes to the engine, letters with where they were tapped. A key it doesn't take
     * (a digit, a symbol, Enter, Delete with no word typed) does what it does after the engine committed the
     * word being typed. On the engine thread too, after the keys before it (#241).
     */
    private fun english(code: Code, text: String, x: Int, y: Int) {
        /**
         * [sym] to the engine; if it doesn't take it, [otherwise] in the field, where [typed] goes on the
         * engine thread's copy of the text (null: Delete's character comes off).
         */
        fun send(sym: () -> Int, typed: String?, otherwise: () -> Unit) {
            englishKeysAhead.incrementAndGet()
            NativeCore.post({
                englishKeysAhead.decrementAndGet()
                val s = sym()
                val st = (if (x >= 0) keyAt(s, 0, x, y) else key(s, 0)).recorded()
                if (st.deleteBefore > 0) engineBefore.setLength(maxOf(0, engineBefore.length - st.deleteBefore))
                engineBefore.append(st.commit)
                if (!st.taken) {
                    if (typed != null) engineBefore.append(typed) else if (engineBefore.isNotEmpty()) engineBefore.setLength(engineBefore.length - 1)
                }
                st
            }) {
                show(it)
                if (!it.taken) otherwise()
            }
            // The key's text shows first; its suggestions follow, unless another key is on its way (#310).
            NativeCore.post({ if (englishKeysAhead.get() == 0) settle() else null }) { if (it != null) show(it, applyText = false) }
        }
        when (code) {
            Code.TEXT -> {
                val cp = text.codePointAt(0)
                if (Character.charCount(cp) != text.length) return NativeCore.post({ flush().recorded() }) {
                    show(it)
                    editor.commit(text)
                }
                if (!Character.isLetter(cp) || keyboard.typedWithUserShift) return send({ NativeCore.charSym(cp) }, text) { editor.commit(text) }
                // The field's capital, by the text this letter follows once the keys before it are in
                val caps = if (Prefs[Prefs.CAPITALISE]) editor.capsFlags else 0
                val lower = text.lowercase()
                var cased = lower
                send({
                    val upper = caps != 0 &&
                        android.text.TextUtils.getCapsMode("$engineBefore$enginePreedit", engineBefore.length + enginePreedit.length, caps) != 0
                    cased = if (upper) lower.uppercase() else lower
                    NativeCore.charSym(cased.codePointAt(0))
                }, lower) { editor.commit(cased) }
            }
            Code.SPACE -> send({ ' '.code }, " ") { editor.commit(" ") }
            Code.ENTER -> send({ NativeCore.XK_Return }, "\n") { editor.enter() }
            else -> send({ NativeCore.XK_BackSpace }, null) { editor.deleteBefore() }
        }
    }

    /** Text into the field, after what the keys before it typed. */
    private fun commit(text: String) = NativeCore.after { editor.commit(text) }

    private fun setPage(page: Page) {
        this.page = page
        refresh()
    }

    private fun nextLanguage() {
        NativeCore.drain() // what the keys before typed shows in this language
        val order = Engines.languages()
        val next = order[(order.indexOf(lang) + 1) % order.size]
        // What is being typed is dropped (core/ doesn't commit it on a switch); English's word stays as it shows,
        // as today's app keeps it, and a word reopened was the field's text already (#280).
        if (lang == ENGLISH) editor.finishComposing() else editor.compose("")
        strip.preedit = ""
        Engines.inUse(lang, false)
        lang = next
        texts.language = lang
        // Written at once: the process may be stopped right after a switch, and the next start must be in it.
        prefs.edit().putInt("language", lang).commit()
        page = Page.LETTERS
        shown = Panel.NONE
        expanded = false
        enterLanguage()
        refresh()
    }

    private var layoutSent: List<Int>? = null

    override fun onLayout(width: Int, height: Int, keys: IntArray) {
        val sig = listOf(width, height) + keys.toList()
        if (sig == layoutSent) return
        layoutSent = sig
        val copy = keys.copyOf()
        NativeCore.post { setLayout(width, height, copy) }
    }

    /** The space bar's swipe: in 中文's and 日本語's composition the engine's cursor, elsewhere the field's. */
    override fun onCursor(by: Int) {
        val english = lang == ENGLISH
        val sym = if (by < 0) NativeCore.XK_Left else NativeCore.XK_Right
        NativeCore.post({
            when {
                !engineComposing -> null
                english -> listOf(flush().recorded())
                else -> List(kotlin.math.abs(by)) { key(sym, 0) }.also { it.lastOrNull()?.recorded() }
            }
        }) { states ->
            states?.forEach { show(it) }
            if (states == null || english) editor.moveBy(by)
            // As any cursor move, into a word reopens it (#280)
            if (english && toEngine) englishContext()
        }
    }

    /** Delete's swipe: what is being typed goes (English's word is kept, as typed), then whole words. */
    override fun onDeleteWords(words: Int, done: Boolean) {
        val english = lang == ENGLISH
        NativeCore.post({ if (engineComposing) (if (english) flush() else clear()).recorded() else null }) { st ->
            if (st != null) {
                if (!english) editor.compose("")
                show(st)
            }
            editor.selectWordsBefore(words, done)
            if (done) autoShift()
        }
    }

    override fun onPickKeyboard() {
        getSystemService(InputMethodManager::class.java).showInputMethodPicker()
    }

    /** English's Shift for the start of a sentence, as the field asks. */
    private fun autoShift() {
        if (!views || keyboard.shift == KeyboardView.Shift.LOCKED) return
        val on = lang == ENGLISH && kind.pad == null && page == Page.LETTERS && Prefs[Prefs.CAPITALISE] && editor.capsMode()
        keyboard.setShift(if (on) KeyboardView.Shift.ON else KeyboardView.Shift.OFF)
    }

    /** The engine's state after a call: its text into the field (unless [applyText] is false), the rest shown. */
    private fun show(st: NativeState, applyText: Boolean = true, around: Editor.Around? = null) {
        if (applyText) {
            editor.beginBatch()
            // A word reopened from [around] is marked only where the field still has it (#280)
            if (st.recompose && !editor.composeRegion(st.composeBefore, st.composeAfter, around?.text(st.composeBefore, st.composeAfter))) {
                editor.endBatch()
                return englishContext()
            }
            if (st.deleteBefore > 0 || st.deleteAfter > 0) editor.delete(st.deleteBefore, st.deleteAfter)
            if (st.commit.isNotEmpty()) editor.commit(st.commit)
            if (st.commit.isNotEmpty() && lang == CHINESE) Sync.onChineseCommit(this)
            if (st.commitCursor != 0) editor.moveCursor(st.commitCursor)
            if (lang != CHINESE) editor.compose(composition(st))
            editor.endBatch()
        }
        state = st
        if (expanded && st.candidates.isEmpty()) expanded = false
        refresh()
    }

    /** 日本語's composition: the segment being converted highlighted, the rest underlined. */
    private fun composition(st: NativeState): CharSequence {
        val out = SpannableStringBuilder()
        st.segments.forEachIndexed { i, s ->
            val start = out.length
            out.append(s)
            val span: Any = if (st.highlighted.getOrElse(i) { false }) BackgroundColorSpan(Picnic.PINK) else UnderlineSpan()
            out.setSpan(span, start, out.length, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
        return out
    }

    // --- What shows ---

    private fun refresh() {
        if (!views) return
        val code = when (lang) { CHINESE -> "zh"; JAPANESE -> "ja"; else -> "en" }
        val layout = Layout.load(this, kind.pad ?: page.file, code)
        val numberRow = if ((kind.numberRow || Prefs[Prefs.NUMBER_ROW]) && kind.pad == null && page == Page.LETTERS) Layout.load(this, "numbers", code) else null
        keyboard.setPage(layout, numberRow, if (lang == ENGLISH) "$" else "¥")
        keyboard.spaceLabel = when (lang) { CHINESE -> "中文"; JAPANESE -> "日本語"; else -> "English" }
        if (lang == JAPANESE) {
            val keys = if (page == Page.LETTERS) NativeCore.KEYS_KANA else NativeCore.KEYS_SYMBOLS
            val landscape = resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
            val sent = keys * 2 + if (landscape) 1 else 0
            if (sent != keysSent) {
                keysSent = sent
                NativeCore.post { setKeys(keys, landscape) }
            }
        }

        val st = state
        strip.preedit = if (lang == CHINESE) st?.preedit.orEmpty() else ""
        // English's word may name an emoji: it takes the bar's third place
        val named = if (lang == ENGLISH && composing && kind.pad == null && Prefs[Prefs.EMOJI_SUGGESTIONS])
            Emoji.forWord(this, st!!.preedit) else null
        val candidates = (st?.candidates?.toMutableList() ?: mutableListOf()).also { list ->
            emojiAt = if (named != null) minOf(2, list.size) else -1
            if (named != null) list.add(emojiAt, named)
            emojiShown = named.orEmpty()
        }
        val notice = if (lang != CHINESE || kind.pad != null) null else when (Engines.chinese) {
            Engines.Chinese.PREPARING -> getString(R.string.chinese_preparing)
            Engines.Chinese.FAILED -> getString(R.string.chinese_failed)
            Engines.Chinese.READY -> null
        }
        val badge = when {
            searching != null -> CandidateBar.Badge.NONE
            incognito -> CandidateBar.Badge.TOGGLE
            kind.incognito -> CandidateBar.Badge.FIELD
            else -> CandidateBar.Badge.NONE
        }
        val chip = if (lang == JAPANESE && kind.pad == null) (if (katakana) "ア" else "あ") else null
        val header = if (searching != null) null else when (shown) {
            Panel.NONE -> null
            Panel.ACTIONS -> CandidateBar.Header(texts[R.string.menu_title], texts[R.string.edit_shortcuts])
            Panel.EDIT -> CandidateBar.Header(texts[R.string.edit_shortcuts], texts[R.string.edit_done])
            Panel.EMOJI -> CandidateBar.Header(texts[R.string.action_emoji], null, texts[R.string.emoji_search], pill = true)
            Panel.CLIPBOARD -> CandidateBar.Header(texts[R.string.action_clipboard], null,
                if (clipboard.keep) texts[R.string.clipboard_search] else null)
            Panel.MODES -> CandidateBar.Header(texts[R.string.action_modes], texts[R.string.mode_resize])
        }
        // What was just copied, while nothing is typed; never in a password or private field (#281)
        val clip = clipboard.quickClip?.takeIf { !composing && kind.pad == null && searching == null && !secretField }
        bar.removeCallbacks(refreshClip)
        if (clip != null) bar.postDelayed(refreshClip, 5_000)
        val style = when (lang) {
            ENGLISH -> CandidateBar.Style.SLOTS
            JAPANESE -> CandidateBar.Style.WIDE_FIRST
            else -> CandidateBar.Style.CELLS
        }
        bar.show(candidates, composing, style, lang == ENGLISH && composing && st?.selected == 0, barOpen, chip, badge, notice,
            header, expanded, clip)
        val on = if (incognito) setOf(Action.INCOGNITO) else emptySet()
        val traditional = if (lang == CHINESE) Engines.setting("Chinese", "Traditional") == true else null
        // The action bar: open, over the bar; never over a panel's title
        val rowShown = barOpen && shown == Panel.NONE
        actionRow.visibility = if (rowShown) View.VISIBLE else View.GONE
        val overKeys = shown != Panel.NONE && shown != Panel.MODES && searching == null
        content.extra = if (barOpen && overKeys) (ActionRow.HEIGHT_DP * resources.displayMetrics.density).toInt() else 0
        if (rowShown) actionRow.show(Action.pinned(this), on)
        val autofilling = autofill.showing && candidates.isEmpty() && shown == Panel.NONE
        autofill.visibility = if (autofilling) View.VISIBLE else View.GONE
        bar.visibility = if (autofilling) View.INVISIBLE else View.VISIBLE
        if (expanded) grid.show(candidates, bar.shownCount())
        when (shown) {
            Panel.ACTIONS, Panel.EDIT -> actions.show(traditional, on, Action.pinned(this), shown == Panel.EDIT)
            Panel.CLIPBOARD -> clips.show()
            Panel.MODES -> modes.show(mode, heightScale, resizing)
            else -> {}
        }
        grid.visibility = if (expanded) View.VISIBLE else View.GONE
        val over = if (expanded || searching != null) null else shown
        searchRow.visibility = if (searching != null) View.VISIBLE else View.GONE
        results.visibility = searchRow.visibility
        // As today's, a search has no bar: its field takes the bar's place
        barFrame.visibility = if (searching != null) View.GONE else View.VISIBLE
        emojiResults.visibility = if (searching == Panel.EMOJI) View.VISIBLE else View.GONE
        clipResults.visibility = if (searching == Panel.CLIPBOARD) View.VISIBLE else View.GONE
        actions.visibility = if (over == Panel.ACTIONS || over == Panel.EDIT) View.VISIBLE else View.GONE
        emoji.visibility = if (over == Panel.EMOJI) View.VISIBLE else View.GONE
        clips.visibility = if (over == Panel.CLIPBOARD) View.VISIBLE else View.GONE
        modes.visibility = if (over == Panel.MODES) View.VISIBLE else View.GONE
        // The keys keep their place (and the keyboard its height) under the grid and the panels.
        keysRow.visibility = if (expanded || overKeys) View.INVISIBLE else View.VISIBLE
    }

    // --- Keyboard modes (#53 B5) ---

    /** The mode and height for this orientation: the keys' width and side, split, floating */
    private fun applyMode() {
        if (!views) return
        val m = mode
        keyboard.heightScale = heightScale
        keyboard.split = m == Mode.SPLIT
        val oneHanded = m == Mode.ONE_HANDED
        (keyboard.layoutParams as LinearLayout.LayoutParams).weight = if (oneHanded) Mode.ONE_HANDED_WIDTH else 1f
        (side.layoutParams as LinearLayout.LayoutParams).weight = if (oneHanded) 1 - Mode.ONE_HANDED_WIDTH else 0f
        side.visibility = if (oneHanded) View.VISIBLE else View.GONE
        // The strip on the side the keys aren't
        val left = prefs.getBoolean("one_handed_left_$orientation", false)
        if ((keysRow.indexOfChild(side) == 0) != !left) {
            keysRow.removeView(side)
            keysRow.addView(side, if (left) 1 else 0)
        }
        val floating = m == Mode.FLOATING
        handle.visibility = if (floating) View.VISIBLE else View.GONE
        val width = resources.displayMetrics.widthPixels
        stack.layoutParams = (stack.layoutParams as FrameLayout.LayoutParams).apply {
            this.width = if (floating) (width * Mode.FLOATING_WIDTH).toInt() else MATCH_PARENT
            gravity = android.view.Gravity.BOTTOM or android.view.Gravity.CENTER_HORIZONTAL
        }
        floatX = prefs.getFloat("floating_x_$orientation", 0f)
        floatY = prefs.getFloat("floating_y_$orientation", 0f)
        placeFloating()
        layoutSent = null
    }

    /**
     * The floating keyboard's place, as shares of the room it has to move in: -1 (left) to 1 (right), and 0
     * (bottom) to 1 (top). Not pixels, so a window resized (split screen, a fold, #283) still shows it.
     */
    private var floatX = 0f
    private var floatY = 0f

    /** Puts the keyboard where [floatX] and [floatY] say, in the window as it is now (after each layout) */
    private fun placeFloating() {
        val floating = mode == Mode.FLOATING
        stack.translationX = if (floating) floatX * ((root.width - stack.width) / 2f).coerceAtLeast(0f) else 0f
        stack.translationY = if (floating) -floatY * (root.height - stack.height).coerceAtLeast(0) else 0f
    }

    /** The floating keyboard dragged by its handle: it stays on the screen. */
    private fun onDrag(dx: Float, dy: Float) {
        val roomX = (root.width - stack.width) / 2f
        val roomY = (root.height - stack.height).toFloat()
        if (roomX > 0) floatX = (floatX + dx / roomX).coerceIn(-1f, 1f)
        if (roomY > 0) floatY = (floatY - dy / roomY).coerceIn(0f, 1f)
        placeFloating()
    }

    private fun saveFloating() {
        prefs.edit().putFloat("floating_x_$orientation", floatX).putFloat("floating_y_$orientation", floatY).apply()
        layoutSent = null
        // A layout pass computes the insets again: the touchable region follows the keyboard.
        stack.requestLayout()
    }

    override fun onMode(mode: Mode) {
        this.mode = mode
        shown = Panel.NONE
        applyMode()
        refresh()
    }

    override fun onHeight(by: Float) {
        heightScale = ((heightScale + by) * 20).roundToInt() / 20f
        heightScale = heightScale.coerceIn(Mode.MIN_HEIGHT, Mode.MAX_HEIGHT)
        applyMode()
        refresh()
    }

    private fun onSwapSide() {
        val key = "one_handed_left_$orientation"
        prefs.edit().putBoolean(key, !prefs.getBoolean(key, false)).apply()
        applyMode()
    }

    // --- Inline autofill (#53 B9): the password manager's chips over the bar ---

    override fun onCreateInlineSuggestionsRequest(uiExtras: Bundle): InlineSuggestionsRequest? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && views) autofill.request(bar.height.takeIf { it > 0 } ?: (40 * resources.displayMetrics.density).toInt())
        else null

    override fun onInlineSuggestionsResponse(response: InlineSuggestionsResponse): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R || !views) return false
        autofill.show(response.inlineSuggestions, bar.height) { refresh() }
        return true
    }

    // --- The bar, the action bar and the panels ---

    override fun onCandidate(index: Int) {
        expanded = false
        val emoji = emojiAt
        if (emoji < 0 || index < emoji) return NativeCore.post({ selectCandidate(index).recorded() }) { show(it) }
        if (index > emoji) return NativeCore.post({ selectCandidate(index - 1).recorded() }) { show(it) }
        // The emoji in place of the word
        val text = emojiShown
        NativeCore.post({ clear().recorded() }) {
            show(it)
            editor.commit(text)
            englishContext()
        }
    }

    /** The bar's › and ^ (opening and closing the action bar), or ← over a panel (Edit actions goes back to All Actions) */
    override fun onMenu() {
        if (searching != null) return endSearch()
        when (shown) {
            Panel.NONE -> barOpen = !barOpen
            Panel.EDIT -> shown = Panel.ACTIONS
            else -> shown = Panel.NONE
        }
        expanded = false
        refresh()
    }

    override fun onAllActions() = open(Panel.ACTIONS)

    override fun onHeaderButton() {
        if (shown != Panel.MODES) return open(if (shown == Panel.ACTIONS) Panel.EDIT else Panel.ACTIONS)
        resizing = !resizing
        refresh()
    }

    private fun open(panel: Panel) {
        shown = panel
        resizing = false
        expanded = false
        if (panel == Panel.EMOJI) emoji.open()
        if (panel == Panel.CLIPBOARD) clipboard.prune()
        refresh()
    }

    override fun onAction(action: Action) {
        when (action) {
            Action.EMOJI -> return open(Panel.EMOJI)
            Action.CLIPBOARD -> return open(Panel.CLIPBOARD)
            Action.MODES -> return open(Panel.MODES)
            Action.INCOGNITO -> return onIncognito(!incognito)
            Action.LANGUAGE -> nextLanguage()
            Action.SETTINGS -> finishTyping {
                startActivity(Intent(this, SettingsActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                requestHideSelf(0)
            }
            Action.UNDO, Action.REDO -> finishTyping { editor.undo(action == Action.REDO) }
            Action.SELECT_ALL, Action.CUT, Action.COPY, Action.PASTE -> finishTyping {
                editor.menuAction(when (action) {
                    Action.SELECT_ALL -> android.R.id.selectAll
                    Action.CUT -> android.R.id.cut
                    Action.COPY -> android.R.id.copy
                    else -> android.R.id.paste
                })
            }
        }
        // An edit from All Actions goes back to the keys, to see it.
        if (shown != Panel.NONE) open(Panel.NONE)
    }

    override fun onPinned(actions: List<Action>) {
        Action.setPinned(this, actions)
        refresh()
    }

    /** What is being typed goes into the field as it is (中文's pinyin is dropped), then [then]: an edit that isn't typing */
    private fun finishTyping(then: () -> Unit) {
        val chinese = lang == CHINESE
        NativeCore.post({ if (engineComposing) (if (chinese) clear() else flush()).recorded() else null }) { st ->
            if (st != null) {
                show(st)
                if (!chinese) editor.finishComposing()
            }
            then()
        }
    }

    // From a search's results it goes into the field, and the search stays, as today's.
    override fun onEmoji(text: String, face: Boolean) = intoField(endsSearch = false) {
        // An ASCII face gets a space either side, as today's
        if (!face) return@intoField fieldEditor.commit(text)
        val before = fieldEditor.textBefore(1)
        fieldEditor.commit((if (before.isEmpty() || before.last().isWhitespace()) "" else " ") + text + " ")
    }

    override fun onLetters() = open(Panel.NONE)

    override fun onDelete() = onKey(Code.DELETE, "", -1, -1)

    override fun onClip() {
        val quick = clipboard.quickClip ?: return
        intoField {
            if (quick.text != null) fieldEditor.commit(quick.text)
            else quick.uri?.let { pasteImage(it, quick.mimeTypes) }
        }
        clipboard.dropQuick()
    }

    private fun onPasteClip(clip: Clipboard.Clip) {
        intoField {
            val file = clipboard.imageFile(clip)
            if (clip.text != null) fieldEditor.commit(clip.text)
            else if (file != null) pasteImage(ClipProvider.share(this, file, clip.mimeTypes.firstOrNull() ?: "image/png"), clip.mimeTypes)
        }
        clipboard.pasted(clip)
        clipboard.dropQuick()
        if (shown == Panel.CLIPBOARD) open(Panel.NONE)
    }

    /** An image into the field, for apps that take one (today's paste); a note for those that don't */
    private fun pasteImage(uri: Uri, mimeTypes: List<String>) {
        val info = currentInputEditorInfo
        val ic = currentInputConnection
        // The history's own images are granted by the paste; another app's (the quick clip's) only if it lets us.
        try {
            if (info != null) grantUriPermission(info.packageName, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (e: SecurityException) {}
        val pasted = info != null && ic != null && InputConnectionCompat.commitContent(ic, info,
            InputContentInfoCompat(uri, ClipDescription("", mimeTypes.toTypedArray()), null),
            InputConnectionCompat.INPUT_CONTENT_GRANT_READ_URI_PERMISSION, null)
        if (!pasted) Toast.makeText(this, texts[R.string.image_unsupported], Toast.LENGTH_SHORT).show()
    }

    /** Into the field, what is typed there first going in as it is; from a search, which then ends ([endsSearch]). */
    private fun intoField(endsSearch: Boolean = true, then: () -> Unit) {
        if (searching == null) return finishTyping(then)
        then()
        if (endsSearch) endSearch()
    }

    /** A password field, or a private one (a private browser tab): the quick clip isn't offered there. */
    private val secretField get() = kind.field == NativeCore.FIELD_PASSWORD ||
        (currentInputEditorInfo?.imeOptions ?: 0) and EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING != 0

    // --- Search (#281) ---

    /** The emoji or clipboard panel's search: the keys type into it, over its results. */
    override fun onSearch() {
        val panel = shown
        finishTyping {
            searching = panel
            search.clear()
            editor = searchEditor
            kind = FieldKind.of(search.info)
            editor.start(search.info, kind)
            keyboard.enter = kind.enter
            page = Page.LETTERS
            // Two thirds of the bar and keys, which the search's field and results replace: today's results
            // take two thirds of its keyboard view, which has the room our bar takes.
            results.layoutParams = results.layoutParams.apply { height = ((barFrame.height + keysRow.height) / 1.5f).toInt() }
            enterLanguage()
            onSearchText("")
            refresh()
            autoShift()
        }
    }

    private fun onSearchText(query: String) {
        emojiResults.query = query
        clipResults.query = query
        searchRow.show(query, texts[if (searching == Panel.CLIPBOARD) R.string.clipboard_search_hint else R.string.emoji_search])
    }

    /** Back to the keys and the field: what is typed in the search stays there. */
    private fun endSearch() {
        if (searching == null) return
        finishTyping {
            searching = null
            editor = fieldEditor
            kind = FieldKind.of(currentInputEditorInfo)
            keyboard.enter = kind.enter
            enterLanguage()
            open(Panel.NONE)
            autoShift()
        }
    }

    override fun onChip() {
        katakana = !katakana
        val on = katakana
        NativeCore.post({
            setAlternate(on)
            state().recorded()
        }) { show(it) }
    }

    override fun onIncognito() = onIncognito(!incognito)

    override fun onExpand() {
        expanded = !expanded
        refresh()
    }

    override fun onNotice() {
        if (Engines.chinese == Engines.Chinese.FAILED) Engines.retryChinese(this)
    }

    override fun onTraditional(on: Boolean) {
        // core/ turns rime-ice's option on at once and saves the choice in sebtype.conf (#36).
        NativeCore.post({
            Engines.setSetting(this@SebTypeIme, "Chinese", "Traditional", on)
            state().recorded()
        }) { show(it) }
    }

    private fun onIncognito(on: Boolean) {
        prefs.edit().putBoolean("incognito", on).apply()
        val field = field()
        val learning = kind.learns && !on
        NativeCore.post { setField(field, learning) }
        refresh()
    }
}

/** An update gets 中文 ready before the keyboard next shows (#40). */
class UpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) Engines.prepareChinese(context)
    }
}

/**
 * Holds the keys, and the expanded candidates and the panels over them at exactly the keys' height, plus
 * [extra]: the action bar's row while a panel takes its place, so the keyboard keeps its height.
 */
private class KeysFrame(context: Context) : FrameLayout(context) {
    var extra = 0
        set(value) {
            if (field != value) requestLayout()
            field = value
        }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val keys = getChildAt(0)
        keys.measure(widthMeasureSpec, MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED))
        val height = keys.measuredHeight + extra
        val exact = MeasureSpec.makeMeasureSpec(height, MeasureSpec.EXACTLY)
        for (i in 1 until childCount) getChildAt(i).measure(widthMeasureSpec, exact)
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), height)
    }
}
