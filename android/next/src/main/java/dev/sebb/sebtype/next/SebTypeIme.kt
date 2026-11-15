package dev.sebb.sebtype.next

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Rect
import android.inputmethodservice.InputMethodService
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.BackgroundColorSpan
import android.text.style.UnderlineSpan
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import dev.sebb.sebtype.core.NativeCore
import dev.sebb.sebtype.core.NativeCore.CHINESE
import dev.sebb.sebtype.core.NativeCore.ENGLISH
import dev.sebb.sebtype.core.NativeCore.JAPANESE
import dev.sebb.sebtype.core.NativeState
import dev.sebb.sebtype.next.Layout.Code

/**
 * SebType's own keyboard (#191, stage 3). English types the letters as they are (its suggestions come in
 * stage 2); 中文 and 日本語 go through core/ ([NativeCore]): each key goes to the engine, and what it
 * returns (text to commit, the composition, candidates) is shown. 中文's pinyin floats above the bar,
 * 日本語's composition sits in the field.
 */
class SebTypeIme : InputMethodService(), KeyboardView.Listener, CandidateBar.Listener, MenuPanel.Listener {
    private enum class Page(val file: String) { LETTERS("letters"), SYMBOLS("symbols"), SYMBOLS2("symbols2") }

    private val prefs by lazy { getSharedPreferences("keyboard", MODE_PRIVATE) }
    private val editor = Editor(this)

    private lateinit var panel: ClothPanel
    private lateinit var strip: PreeditStrip
    private lateinit var bar: CandidateBar
    private lateinit var keyboard: KeyboardView
    private lateinit var grid: CandidateGrid
    private lateinit var menu: MenuPanel
    private var views = false

    private var lang = ENGLISH
    private var page = Page.LETTERS
    private var kind = FieldKind.of(null)
    private var katakana = false
    private var menuOpen = false
    private var expanded = false
    private var state: NativeState? = null

    private val incognito get() = prefs.getBoolean("incognito", false)
    private val composing get() = state?.preedit?.isNotEmpty() == true

    override fun onCreate() {
        super.onCreate()
        Engines.configure(this)
        Engines.prepareChinese(this)
        Engines.onChange = { if (views) refresh() }
        // A fresh install starts in English (#35).
        lang = prefs.getInt("language", ENGLISH).takeIf { it in Engines.languages() } ?: ENGLISH
    }

    override fun onDestroy() {
        Engines.onChange = null
        Engines.saveJapanese()
        super.onDestroy()
    }

    override fun onCreateInputView(): View {
        val root = FrameLayout(this)
        val popups = PopupLayer(this)
        strip = PreeditStrip(this)
        panel = ClothPanel(this)
        bar = CandidateBar(this, this)
        keyboard = KeyboardView(this, popups, this)
        grid = CandidateGrid(this) { onCandidate(it) }
        menu = MenuPanel(this, this)
        val content = FrameLayout(this)
        content.addView(keyboard, FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        content.addView(grid, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        content.addView(menu, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        panel.addView(bar, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        panel.addView(content, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        val stack = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        stack.addView(strip, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        stack.addView(panel, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
        root.addView(stack, FrameLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT, android.view.Gravity.BOTTOM))
        root.addView(popups, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        // The keys stay clear of the navigation bar the window reaches under.
        ViewCompat.setOnApplyWindowInsetsListener(panel) { v, insets ->
            v.setPadding(0, 0, 0, insets.getInsets(WindowInsetsCompat.Type.navigationBars()).bottom)
            insets
        }
        views = true
        return root
    }

    override fun onEvaluateFullscreenMode() = false

    /** The app sees the keyboard from the bar down; the floating pinyin above it lets touches through. */
    override fun onComputeInsets(outInsets: Insets) {
        super.onComputeInsets(outInsets)
        if (!views || !panel.isShown) return
        val at = IntArray(2).also { panel.getLocationInWindow(it) }
        outInsets.contentTopInsets = at[1]
        outInsets.visibleTopInsets = at[1]
        outInsets.touchableInsets = Insets.TOUCHABLE_INSETS_REGION
        outInsets.touchableRegion.set(Rect(at[0], at[1], at[0] + panel.width, at[1] + panel.height))
    }

    override fun onStartInput(info: EditorInfo, restarting: Boolean) {
        super.onStartInput(info, restarting)
        kind = FieldKind.of(info)
        editor.start(info, kind)
        state = null
    }

    override fun onStartInputView(info: EditorInfo, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        if (!restarting) {
            page = Page.LETTERS
            menuOpen = false
            expanded = false
        }
        enterLanguage()
        keyboard.enter = kind.enter
        refresh()
        autoShift()
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        super.onFinishInputView(finishingInput)
        Engines.inUse(lang, false)
        Engines.saveJapanese()
    }

    override fun onFinishInput() {
        super.onFinishInput()
        if (composing) NativeCore.clear()
        editor.finishComposing()
        state = null
        if (views) strip.preedit = ""
    }

    override fun onUpdateSelection(oldSelStart: Int, oldSelEnd: Int, newSelStart: Int, newSelEnd: Int,
                                   candidatesStart: Int, candidatesEnd: Int) {
        super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart, candidatesEnd)
        val external = editor.selectionChanged(newSelStart, newSelEnd, candidatesStart, candidatesEnd)
        // The user moved the cursor away: what was being typed stays as it is in the field.
        if (external && composing) {
            editor.finishComposing()
            show(NativeCore.clear(), applyText = false)
        }
        if (views) autoShift()
    }

    /** The current language for this field: core/'s engine, its field kind, the keys. */
    private fun enterLanguage() {
        NativeCore.clear()
        NativeCore.selectLanguage(lang)
        NativeCore.setField(kind.field, kind.learns && !incognito)
        when (lang) {
            CHINESE -> Engines.prepareChinese(this)
            JAPANESE -> {
                // A new field (or 日本語 again) starts on あ (#38).
                katakana = false
                NativeCore.setAlternate(false)
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
        JAPANESE -> true
        else -> false
    }

    override fun onKey(code: Code, text: String) {
        when (code) {
            Code.TEXT -> type(text)
            Code.SPACE -> if (toEngine && composing) engine(NativeCore.charSym(' '.code)) else commit(" ")
            Code.ENTER -> if (toEngine && composing) engine(NativeCore.XK_Return) else editor.enter()
            Code.DELETE -> if (toEngine && composing) engine(NativeCore.XK_BackSpace) else editor.deleteBefore()
            Code.SYMBOLS -> setPage(if (page == Page.LETTERS || page == Page.SYMBOLS2) Page.SYMBOLS else Page.LETTERS)
            Code.SYMBOLS2 -> setPage(Page.SYMBOLS2)
            Code.LETTERS -> setPage(Page.LETTERS)
            Code.GLOBE -> nextLanguage()
            Code.SHIFT, Code.GAP -> {}
        }
        autoShift()
    }

    private fun type(text: String) {
        if (!toEngine) return commit(text)
        val cp = text.codePointAt(0)
        if (Character.charCount(cp) == text.length && cp < 0x80) {
            val st = NativeCore.key(NativeCore.charSym(cp), 0)
            show(st)
            if (!st.taken) commit(text)
            return
        }
        // A long-press choice the engine has no key for (？, …): what is typed goes first. In 中文 that is
        // the first candidate, as Rime's own punctuation does.
        if (composing) {
            show(if (lang == CHINESE && state?.candidates?.isNotEmpty() == true) NativeCore.selectCandidate(0) else NativeCore.flush())
            if (composing) show(NativeCore.flush())
        }
        commit(text)
    }

    private fun engine(sym: Int) = show(NativeCore.key(sym, 0))

    private fun commit(text: String) {
        editor.commit(text)
    }

    private fun setPage(page: Page) {
        this.page = page
        refresh()
    }

    private fun nextLanguage() {
        val order = Engines.languages()
        val next = order[(order.indexOf(lang) + 1) % order.size]
        // What is being typed is dropped (core/ doesn't commit it on a switch).
        editor.compose("")
        strip.preedit = ""
        Engines.inUse(lang, false)
        lang = next
        prefs.edit().putInt("language", lang).apply()
        page = Page.LETTERS
        menuOpen = false
        expanded = false
        enterLanguage()
        refresh()
    }

    override fun onPickKeyboard() {
        getSystemService(InputMethodManager::class.java).showInputMethodPicker()
    }

    /** English's Shift for the start of a sentence, as the field asks. */
    private fun autoShift() {
        if (!views || keyboard.shift == KeyboardView.Shift.LOCKED) return
        val on = lang == ENGLISH && kind.pad == null && page == Page.LETTERS && editor.capsMode()
        keyboard.setShift(if (on) KeyboardView.Shift.ON else KeyboardView.Shift.OFF)
    }

    /** The engine's state after a call: its text into the field (unless [applyText] is false), the rest shown. */
    private fun show(st: NativeState, applyText: Boolean = true) {
        if (applyText) {
            editor.beginBatch()
            if (st.deleteBefore > 0 || st.deleteAfter > 0) editor.delete(st.deleteBefore, st.deleteAfter)
            if (st.commit.isNotEmpty()) editor.commit(st.commit)
            if (st.commitCursor != 0) editor.moveCursor(st.commitCursor)
            if (lang == JAPANESE) editor.compose(composition(st))
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
        val numberRow = if (kind.numberRow && kind.pad == null && page == Page.LETTERS) Layout.load(this, "numbers", code) else null
        keyboard.setPage(layout, numberRow, if (lang == ENGLISH) "$" else "¥")
        keyboard.spaceLabel = when (lang) { CHINESE -> "中文"; JAPANESE -> "日本語"; else -> "English" }
        if (lang == JAPANESE) NativeCore.setKeys(if (page == Page.LETTERS) NativeCore.KEYS_KANA else NativeCore.KEYS_SYMBOLS,
            resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE)

        val st = state
        strip.preedit = if (lang == CHINESE) st?.preedit.orEmpty() else ""
        val candidates = st?.candidates?.toList().orEmpty()
        val notice = if (lang != CHINESE || kind.pad != null) null else when (Engines.chinese) {
            Engines.Chinese.PREPARING -> getString(R.string.chinese_preparing)
            Engines.Chinese.FAILED -> getString(R.string.chinese_failed)
            Engines.Chinese.READY -> null
        }
        val badge = when {
            incognito -> CandidateBar.Badge.TOGGLE
            kind.incognito -> CandidateBar.Badge.FIELD
            else -> CandidateBar.Badge.NONE
        }
        val chip = if (lang == JAPANESE && kind.pad == null) (if (katakana) "ア" else "あ") else null
        bar.show(candidates, chip, badge, notice, menuOpen, expanded)
        if (expanded) grid.show(candidates)
        if (menuOpen) menu.show(if (lang == CHINESE) Engines.setting("Chinese", "Traditional") == true else null, incognito)
        grid.visibility = if (expanded) View.VISIBLE else View.GONE
        menu.visibility = if (menuOpen && !expanded) View.VISIBLE else View.GONE
        // The keys keep their place (and the keyboard its height) under the grid and the menu.
        keyboard.visibility = if (expanded || menuOpen) View.INVISIBLE else View.VISIBLE
    }

    // --- The bar and the menu ---

    override fun onCandidate(index: Int) {
        expanded = false
        show(NativeCore.selectCandidate(index))
    }

    override fun onMenu() {
        menuOpen = !menuOpen
        expanded = false
        refresh()
    }

    override fun onChip() {
        katakana = !katakana
        NativeCore.setAlternate(katakana)
        show(NativeCore.state())
    }

    override fun onIncognito() = onIncognito(!incognito)

    override fun onExpand() {
        expanded = !expanded
        menuOpen = false
        refresh()
    }

    override fun onNotice() {
        if (Engines.chinese == Engines.Chinese.FAILED) Engines.retryChinese(this)
    }

    override fun onTraditional(on: Boolean) {
        // core/ turns rime-ice's option on at once and saves the choice in sebtype.conf (#36).
        Engines.setSetting(this, "Chinese", "Traditional", on)
        show(NativeCore.state())
    }

    override fun onIncognito(on: Boolean) {
        prefs.edit().putBoolean("incognito", on).apply()
        NativeCore.setField(kind.field, kind.learns && !on)
        refresh()
    }
}

/** An update gets 中文 ready before the keyboard next shows (#40). */
class UpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) Engines.prepareChinese(context)
    }
}
