package dev.sebb.sebtype

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Rect
import android.graphics.RectF
import android.os.Bundle
import android.os.SystemClock
import android.media.AudioManager
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.ViewConfiguration
import android.view.View
import android.view.accessibility.AccessibilityEvent
import androidx.core.view.ViewCompat
import androidx.core.view.accessibility.AccessibilityNodeInfoCompat
import androidx.customview.widget.ExploreByTouchHelper
import dev.sebb.sebtype.Icons.Icon
import dev.sebb.sebtype.Layout.Code
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.min
import kotlin.math.roundToInt

private operator fun RectF.component1() = left
private operator fun RectF.component2() = top
private operator fun RectF.component3() = right
private operator fun RectF.component4() = bottom

/**
 * The keys: one View drawn on a Canvas. It lays out a [Layout] page (with the number row over it when
 * asked), draws it in the Picnic look and turns touches into keys: a tap types on release, a long press
 * opens the key's choices, Delete repeats while held, a second finger types the first key at once, a finger
 * slid onto another letter types that one. Every
 * key is a virtual view with a text label for TalkBack and the emulator checks (uiautomator).
 */
@SuppressLint("ViewConstructor")
class KeyboardView(context: Context, private val popups: PopupLayer, private val listener: Listener) : View(context) {
    interface Listener {
        /** A key: its text (Shift applied) for a text key, and where it was tapped (-1, -1: not tapped) */
        fun onKey(code: Code, text: String, x: Int, y: Int)
        /** A long press on 🌐: the system's keyboard picker */
        fun onPickKeyboard()
        /** The letter keys moved: five ints a key (its letter, x, y, width, height), for English's corrections */
        fun onLayout(width: Int, height: Int, keys: IntArray)
        /** The space bar swiped sideways: the cursor moves [by] characters (#53 B11) */
        fun onCursor(by: Int)
        /** Delete swiped left: [words] words before the cursor selected, deleted when [done] (#53 B11) */
        fun onDeleteWords(words: Int, done: Boolean)
    }

    enum class Shift { OFF, ON, LOCKED }

    private val density = resources.displayMetrics.density
    private val px = Picnic.pixel(context).toFloat()
    /** Rows are as far apart as Gboard's (#161) and today's keyboard, times the height the user set */
    private var rowHeight = ROW * density
    /** The keyboard's height, 1 as today's default */
    var heightScale = 1f
        set(value) {
            if (field == value) return
            field = value
            rowHeight = ROW * density * value
            requestLayout()
        }
    /** Split mode: the keys in two halves, at the sides, with a gap between them */
    var split = false
        set(value) {
            if (field == value) return
            field = value
            layoutCells()
            invalidate()
            a11y.invalidateRoot()
        }
    /** A buzz on each key press (the system's own touch feedback setting also applies) */
    var haptics = true
    /** A click on each key press */
    var sounds = false
    private val audio = context.getSystemService(AudioManager::class.java)
    private val sidePadding = SIDE_PADDING_DP * density
    /** Space between the bar and the first row */
    private val topPadding = TOP_PADDING_DP * density

    private var page: Layout? = null
    private var numberRow: Layout? = null
    /** The rows the keyboard keeps the height of on every page: the letters' with the field's number row (#531) */
    private var fillRows = 0f
    var shift = Shift.OFF
        private set
    /** The space bar's label: the language's name */
    var spaceLabel = ""
        set(value) { field = value; invalidate() }
    /** $, or ¥ in 中文 and 日本語 */
    private var currency = "$"
    var enter = FieldKind.Enter.NEWLINE
        set(value) { field = value; invalidate(); a11y.invalidateRoot() }

    private class Cell(val key: Layout.Key, val box: Box) {
        val rect = RectF(box.left, box.top, box.right, box.bottom)
    }
    private var cells = emptyList<Cell>()
    private var keys = emptyList<Layout.Key>()
    private var boxes = emptyList<Box>()
    /** The keys' text sizes' share of today's: [keyTextScale] of the keys as laid out */
    private var textScale = 1f
    /** The key frames' pixel: today's, smaller with the text on keys smaller than any docked keyboard's */
    private var keyPx = px
    /** The letters' text sizes in px by label, one for the whole keyboard: [letterSizes] */
    private var letters = emptyMap<String, Float>()

    private val fonts = Picnic.fonts(context)
    private val label = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER; typeface = fonts.first }
    private val hint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.RIGHT; typeface = fonts.first; color = Picnic.MUTED; textSize = HINT_DP * density
    }

    private val a11y = Accessibility()

    private companion object {
        /** A key's vibration, as short as a tap */
        const val VIBRATE_MS = 12L
        /** A row's height in dp at the default height */
        const val ROW = 59.3f
        /** Space swipe: key widths per character the cursor moves */
        const val CURSOR_STEP = 0.4f
    }

    init {
        ViewCompat.setAccessibilityDelegate(this, a11y)
        id = R.id.keyboard
    }

    /** [fillRows]: a page with fewer rows stretches them to this many, so the keyboard keeps its height (#531). */
    fun setPage(page: Layout, numberRow: Layout?, currency: String, fillRows: Float = 0f) {
        if (this.page === page && this.numberRow === numberRow && this.currency == currency && this.fillRows == fillRows) return
        val before = tallRows
        this.page = page
        this.numberRow = numberRow
        this.currency = currency
        this.fillRows = fillRows
        cancelTouches()
        if (tallRows != before) requestLayout() else layoutCells()
        invalidate()
        a11y.invalidateRoot()
    }

    /**
     * The user's Shift when the last key was typed: true turned on (or locked), false turned off (the field's
     * capital cancelled, #479), null left as the field set it
     */
    var typedWithUserShift: Boolean? = null
        private set
    private var userShift: Boolean? = null

    fun setShift(shift: Shift) {
        userShift = null
        if (this.shift == shift) return
        this.shift = shift
        invalidate()
        a11y.invalidateRoot()
    }

    private val shownRows get() = numberRow?.rows.orEmpty() + page?.rows.orEmpty()
    /** The keyboard's height in rows */
    private val tallRows get() = maxOf(rowsHeight(shownRows), fillRows)
    /** This page's rows' height in px, stretched to [fillRows] */
    private val pageRowHeight get() = pageRowHeight(shownRows, fillRows, rowHeight)

    /** The keys' height in px at [scale] (a [heightScale]), and the scale that gives them [height] px */
    fun heightAt(scale: Float) = topPadding + tallRows * ROW * density * scale
    fun scaleFor(height: Float) = (height - topPadding) / (tallRows * ROW * density)
    /** The height scale at which four rows are [dp] dp: today's floating keyboard sets its height as four rows' */
    fun scaleForFourRows(dp: Float) = dp / (4 * ROW)

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), ceil(keysHeight(shownRows, pageRowHeight, density)).toInt())
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) = layoutCells()

    private fun layoutCells() {
        val unit = (width - 2 * sidePadding) / 10f
        val half = SPLIT_HALF * (width - 2 * sidePadding) / 5f
        val out = keyCells(shownRows, width.toFloat(), pageRowHeight, density, split)
            .map { (key, b) -> Cell(key, b) }
        cells = out
        keys = out.map { it.key }
        boxes = out.map { it.box }
        textScale = keyTextScale(heightScale, (if (split) half else unit) / density)
        keyPx = maxOf(1, (px * textScale).roundToInt()).toFloat()
        // Sized once for the keyboard, as today's app does from its most common key (KeyboardView.setKeyboard):
        // the widest letter, either case, fits the most common letter key's keycap.
        val letterCells = out.filter { isLetter(it.key) }
        letters = if (letterCells.isEmpty()) emptyMap() else {
            val common = letterCells.groupingBy { it.rect.width().roundToInt() }.eachCount().maxBy { it.value }.key
            val size = LETTER_DP * density * textScale
            // The letters' ink, measured large for a width finer than the bounds' whole pixels
            label.textSize = 1000f
            val ink = Rect()
            letterSizes(letterCells.map { it.key.label }, size, keycapRoom(common.toFloat(), density, textScale, keyPx)) {
                label.getTextBounds(it, 0, it.length, ink)
                ink.width() / 1000f * size
            }
        }
        // Hints 10% larger only beside letters at their full size: next to letters fitted to narrow keys they crowd them
        hint.textSize = (if (letters.values.any { it < LETTER_DP * density * textScale }) 12.5f else HINT_DP) * density
        val letters = out.filter { it.key.code == Code.TEXT && it.key.text.length == 1 && it.key.text[0] in 'a'..'z' }
        if (letters.isNotEmpty()) listener.onLayout(width, height, letters.flatMap {
            val r = it.rect
            listOf(it.key.text[0].code, r.left.roundToInt(), r.top.roundToInt(), r.width().roundToInt(), r.height().roundToInt())
        }.toIntArray())
    }

    // --- Drawing ---

    private fun text(key: Layout.Key) = when {
        key.currency -> currency
        key.code == Code.TEXT && shift != Shift.OFF -> key.text.uppercase()
        else -> key.text
    }

    private fun shown(key: Layout.Key) = when {
        key.currency -> currency
        key.code == Code.TEXT && shift != Shift.OFF -> key.label.uppercase()
        else -> key.label
    }

    private fun icon(key: Layout.Key) = when (key.code) {
        Code.SHIFT -> when (shift) { Shift.OFF -> Icon.SHIFT; Shift.ON -> Icon.SHIFT_ON; Shift.LOCKED -> Icon.SHIFT_LOCKED }
        Code.DELETE -> Icon.DELETE
        Code.GLOBE, Code.KEYBOARDS -> Icon.GLOBE
        Code.ENTER -> when (enter) {
            FieldKind.Enter.NEWLINE, FieldKind.Enter.CUSTOM -> Icon.ENTER
            FieldKind.Enter.SEARCH -> Icon.SEARCH
            FieldKind.Enter.SEND -> Icon.SEND
            FieldKind.Enter.GO, FieldKind.Enter.NEXT -> Icon.NEXT
            FieldKind.Enter.PREVIOUS -> Icon.PREVIOUS
            FieldKind.Enter.DONE -> Icon.DONE
        }
        else -> null
    }

    private fun frame(key: Layout.Key) = when {
        key.code == Code.ENTER || (key.code == Code.SHIFT && shift == Shift.LOCKED) -> PixelFrame.BERRY
        key.function || key.pink -> PixelFrame.PINK
        else -> PixelFrame.CREAM
    }

    override fun onDraw(canvas: Canvas) {
        for (cell in cells) {
            val r = cell.rect
            val key = cell.key
            val pressed = pointers.values.any { it.cell === cell }
            val (l, t, rr, b) = face(r)
            val frame = frame(key)
            frame.draw(canvas, l, t, rr, b, keyPx, pressed)
            // The frame's shadow takes its last pixel right and below: the face's middle is up and left of it.
            val cx = (l + rr - keyPx) / 2 + if (pressed) keyPx / 2 else 0f
            val cy = (t + b - keyPx) / 2 + if (pressed) keyPx / 2 else 0f
            val ink = if (frame === PixelFrame.BERRY) Picnic.WHITE else Picnic.INK
            val icon = icon(key)
            when {
                // On keys smaller than any docked keyboard's, an icon stays within the face's frame too.
                // 10% larger than today's where it fits the face's frame, never smaller than today's on a docked keyboard
                icon != null -> Icons.draw(canvas, icon, cx, cy, min(ICON_DP * density, (b - t) * 0.5f).let {
                    if (textScale < 1f) minOf(it, ICON_DP * density * textScale, rr - l - 5 * keyPx)
                    else min(it, maxOf(rr - l - 5 * keyPx, min(24 * density, (b - t) * 0.5f)))
                }, ink)
                key.code == Code.SPACE && key.label.isBlank() -> {
                    label.textSize = 14.3f * density * textScale
                    // Split's halves of the space bar are narrow: the label shrinks to fit, as today's does
                    val room = rr - l - 12 * density
                    val w = label.measureText(spaceLabel)
                    if (w > room) label.textSize *= room / w
                    label.color = Picnic.FADED
                    canvas.drawText(spaceLabel, cx, cy + label.textSize * 0.35f, label)
                }
                key.label.contains('\n') -> {
                    // The numbers page's key: its digits small, in two lines
                    label.textSize = 12.1f * density * textScale
                    label.color = ink
                    val lines = key.label.split('\n')
                    lines.forEachIndexed { i, line ->
                        canvas.drawText(line, cx, cy + label.textSize * (0.35f + 1.1f * (i - (lines.size - 1) / 2f)), label)
                    }
                }
                else -> {
                    val s = shown(key)
                    label.textSize = letters[key.label] ?: labelSize(cell, s)
                    label.color = ink
                    canvas.drawText(s, cx, cy + label.textSize * 0.35f, label)
                }
            }
            // Hints need a key face of today's size: on smaller ones they crowd the letter, and they go.
            if (hints && textScale == 1f) key.hint?.let { canvas.drawText(it, rr - 3 * px, t + 2 * px + hint.textSize * 0.9f, hint) }
        }
    }

    private fun isLetter(key: Layout.Key) = key.label.length == 1 && key.label[0].isLetter()

    /** Any other label's text size: today's, shrunk to fit a key narrower than it */
    private fun labelSize(cell: Cell, s: String): Float {
        label.textSize = when {
            s.length > 1 -> 14.3f
            cell.rect.height() < rowHeight -> 22f
            // The small punctuation is drawn larger, as today's keyboard does
            s in ",.、。" -> 49.5f
            else -> LETTER_DP
        } * density * textScale
        // On keys smaller than any docked keyboard's, within the frame's outline and shadow
        val (l, _, rr, _) = face(cell.rect)
        val room = rr - l - (if (textScale < 1f) 4 else 2) * keyPx
        val w = label.measureText(s)
        return if (w > room) label.textSize * room / w else label.textSize
    }

    // --- Touch ---

    private class Pointer(var cell: Cell, val downAt: Long, val downX: Float, val downY: Float) {
        var panel: List<Pair<RectF, Layout.Key>>? = null
        var chosen = 0
        /** Shift, held while another key is typed: off again when it is let go */
        var chorded = false
        var x = downX
        var y = downY
        /** Space or Delete swiped sideways: the cursor steps or the words reported so far */
        var swiping = false
        var steps = 0
    }

    private val pointers = HashMap<Int, Pointer>()
    private val slop = ViewConfiguration.get(context).scaledTouchSlop.toFloat()
    /** How far past its key's edge a finger slides onto the next one: today's 8 dp, 40 dp on tablets (config_key_hysteresis_distance) */
    private val hysteresis = (if (resources.configuration.smallestScreenWidthDp >= 600) 40 else 8) * density
    private var lastShiftTap = 0L
    /** The settings' long-press time and key popup ([dev.sebb.sebtype.data.Prefs]) */
    var longPressMs = 300L
    var previews = true
    var hints = true
    /** The vibration's strength, 1–100 % */
    var strength = 50
    private val vibrator = context.getSystemService(android.os.Vibrator::class.java)

    /** A short tap of the motor at [strength]; a swipe's steps get a lighter one. */
    private fun vibrate(light: Boolean) {
        val amplitude = (255 * strength / 100 / (if (light) 2 else 1)).coerceIn(1, 255)
        if (vibrator?.hasAmplitudeControl() == true) vibrator.vibrate(android.os.VibrationEffect.createOneShot(VIBRATE_MS, amplitude))
        else performHapticFeedback(if (light) HapticFeedbackConstants.CLOCK_TICK else HapticFeedbackConstants.KEYBOARD_TAP)
    }
    private val repeatStartMs = 400L
    private val repeatMs = 50L

    private val longPress = Runnable { onLongPress() }
    private val repeat = object : Runnable {
        override fun run() {
            if (pointers.values.none { it.cell.key.code == Code.DELETE && !it.swiping }) return
            listener.onKey(Code.DELETE, "", -1, -1)
            postDelayed(this, repeatMs)
        }
    }

    private fun cellAt(x: Float, y: Float): Cell? = keyAt(boxes, x, y, height.toFloat())?.let { cells[it] }

    /** The letter a held finger at [x], [y] slid onto from its key, if it did; none for a key laid out again since */
    private fun slidTo(p: Pointer, x: Float, y: Float): Cell? =
        cells.indexOf(p.cell).takeIf { it >= 0 }?.let { slidTo(keys, boxes, it, x, y, height.toFloat(), hysteresis) }?.let { cells[it] }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN, MotionEvent.ACTION_POINTER_DOWN -> {
                // A new finger types what the others hold, as fast typing rolls from key to key.
                for ((id, p) in pointers.toMap()) if (p.cell.key.code != Code.SHIFT) release(id, p)
                val i = e.actionIndex
                val cell = cellAt(e.getX(i), e.getY(i)) ?: return true
                press(e.getPointerId(i), cell, e.getX(i), e.getY(i))
            }
            MotionEvent.ACTION_MOVE -> for (i in 0 until e.pointerCount) {
                val p = pointers[e.getPointerId(i)] ?: continue
                p.x = e.getX(i)
                p.y = e.getY(i)
                if (p.panel == null) {
                    swipe(p)
                    slidTo(p, p.x, p.y)?.let { slide(p, it) }
                }
                p.panel?.let { panel ->
                    val x = e.getX(i) + layerOffset()[0]
                    val y = e.getY(i) + layerOffset()[1]
                    val nearest = panel.indices.minByOrNull {
                        val r = panel[it].first
                        abs(r.centerX() - x) + abs(r.centerY() - y) * 0.5f
                    } ?: 0
                    if (nearest != p.chosen) { p.chosen = nearest; showPanel(panel, nearest) }
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_POINTER_UP -> {
                val i = e.actionIndex
                val id = e.getPointerId(i)
                pointers[id]?.let { p ->
                    // Where the finger lifts counts too: a last step past the edge types the letter it ends on
                    p.x = e.getX(i)
                    p.y = e.getY(i)
                    if (p.panel == null) slidTo(p, p.x, p.y)?.let { p.cell = it }
                    release(id, p)
                }
            }
            MotionEvent.ACTION_CANCEL -> cancelTouches()
        }
        return true
    }

    private fun press(id: Int, cell: Cell, x: Float, y: Float) {
        val p = Pointer(cell, SystemClock.uptimeMillis(), x, y)
        pointers[id] = p
        removeCallbacks(longPress)
        feedback(cell.key.code)
        when (cell.key.code) {
            Code.SHIFT -> {
                val now = SystemClock.uptimeMillis()
                val unlocking = shift == Shift.LOCKED
                // A double tap locks from either state, as today's does: the auto-capital's Shift too
                setShift(when {
                    unlocking -> Shift.OFF
                    now - lastShiftTap < 300 -> Shift.LOCKED
                    shift == Shift.OFF -> Shift.ON
                    else -> Shift.OFF
                })
                userShift = shift != Shift.OFF
                lastShiftTap = if (unlocking) 0 else now
            }
            Code.DELETE -> {
                listener.onKey(Code.DELETE, "", -1, -1)
                postDelayed(repeat, repeatStartMs)
            }
            else -> {
                if (cell.key.code == Code.TEXT && previews) showPreview(cell)
                if (cell.key.more.isNotEmpty() || cell.key.code == Code.GLOBE) postDelayed(longPress, longPressMs)
            }
        }
        pointers.values.filter { it.cell.key.code == Code.SHIFT && it !== p }.forEach { it.chorded = true }
        invalidate()
    }

    /** The finger slid onto another letter: it types that one, its preview and long press with it, and buzzes only when it went down */
    private fun slide(p: Pointer, cell: Cell) {
        p.cell = cell
        removeCallbacks(longPress)
        if (previews) showPreview(cell)
        if (cell.key.more.isNotEmpty()) postDelayed(longPress, longPressMs)
        invalidate()
    }

    private fun release(id: Int, p: Pointer) {
        pointers.remove(id)
        removeCallbacks(longPress)
        val key = p.cell.key
        val panel = p.panel
        when {
            panel != null -> panel.getOrNull(p.chosen)?.let { type(it.second) }
            key.code == Code.SHIFT -> if (p.chorded) setShift(Shift.OFF)
            key.code == Code.DELETE -> {
                removeCallbacks(repeat)
                if (p.swiping) listener.onDeleteWords(p.steps, true)
            }
            key.code == Code.SPACE && p.swiping -> {}
            key.code == Code.GLOBE && SystemClock.uptimeMillis() - p.downAt >= longPressMs -> {}
            else -> type(key, p.x.roundToInt(), p.y.roundToInt())
        }
        if (pointers.isEmpty()) popups.clear()
        invalidate()
    }

    private fun type(key: Layout.Key, x: Int = -1, y: Int = -1) {
        val text = text(key)
        typedWithUserShift = userShift
        // Turned off, Shift cancels one capital: the field's capital decides again after it
        if (key.code == Code.TEXT && userShift == false) userShift = null
        // One Shift types one capital; locked, it stays. Held, it lasts until it is let go.
        if (key.code == Code.TEXT && shift == Shift.ON && pointers.values.none { it.cell.key.code == Code.SHIFT }) setShift(Shift.OFF)
        listener.onKey(key.code, text, x, y)
        pointers.values.filter { it.cell.key.code == Code.SHIFT }.forEach { it.chorded = true }
    }

    /**
     * Space swiped sideways moves the cursor a character for every [CURSOR_STEP] key widths; Delete swiped
     * left selects a word for every key width, and deletes them when let go (#53 B11). Once a swipe starts,
     * the key doesn't type or repeat.
     */
    private fun swipe(p: Pointer) {
        val code = p.cell.key.code
        if (code != Code.SPACE && code != Code.DELETE) return
        val dx = p.x - p.downX
        if (!p.swiping) {
            if (abs(dx) < slop || (code == Code.DELETE && dx > 0)) return
            p.swiping = true
            removeCallbacks(longPress)
            removeCallbacks(repeat)
            popups.clear()
        }
        val unit = (width - 2 * sidePadding) / 10f
        if (code == Code.SPACE) {
            val steps = (dx / (CURSOR_STEP * unit)).toInt()
            if (steps != p.steps) {
                listener.onCursor(steps - p.steps)
                p.steps = steps
                feedback(Code.GAP)
            }
        } else {
            val words = if (dx < -slop) 1 + ((-dx - slop) / unit).toInt() else 0
            if (words != p.steps) {
                p.steps = words
                listener.onDeleteWords(words, false)
                feedback(Code.GAP)
            }
        }
    }

    /** A key's buzz and click; [Code.GAP]: a swipe's step, a buzz only */
    private fun feedback(code: Code) {
        if (haptics) vibrate(code == Code.GAP)
        if (sounds && code != Code.GAP) audio.playSoundEffect(when (code) {
            Code.DELETE -> AudioManager.FX_KEYPRESS_DELETE
            Code.ENTER -> AudioManager.FX_KEYPRESS_RETURN
            Code.SPACE -> AudioManager.FX_KEYPRESS_SPACEBAR
            else -> AudioManager.FX_KEYPRESS_STANDARD
        }, -1f)
    }

    private fun cancelTouches() {
        // A cancelled swipe of Delete deletes nothing
        if (pointers.values.any { it.cell.key.code == Code.DELETE && it.swiping }) listener.onDeleteWords(0, true)
        pointers.clear()
        removeCallbacks(longPress)
        removeCallbacks(repeat)
        popups.clear()
        invalidate()
    }

    private fun onLongPress() {
        val (_, p) = pointers.entries.maxByOrNull { it.value.downAt } ?: return
        val key = p.cell.key
        if (key.code == Code.GLOBE) {
            listener.onPickKeyboard()
            return
        }
        p.panel = panelFor(p.cell)
        p.chosen = 0
        showPanel(p.panel!!, p.chosen)
    }

    /**
     * A key's long-press panel: its alternates' cells, in the popup layer's coordinates. Up to five columns,
     * rows as even as they go. The first choice sits over the key, the next ones alternate right and left of
     * it, and rows fill from the bottom up (as AOSP's keyboard places them).
     */
    private fun panelFor(cell: Cell): List<Pair<RectF, Layout.Key>> {
        val key = cell.key
        val unit = (width - 2 * sidePadding) / 10f
        val n = key.more.size
        val rows = (n + 4) / 5
        val cols = (n + rows - 1) / rows
        val cellH = rowHeight * 0.82f
        val r = cell.rect
        val column = ((r.centerX() - sidePadding) / unit).toInt()
        // Columns that fit left and right of the key's own, the rest going to the other side at an edge
        var right = min((cols - 1) - (cols - 1) / 2, 9 - column)
        val left = min(cols - 1 - right, column)
        right = cols - 1 - left
        val order = (0 until cols * 2).map { if (it % 2 == 1) (it + 1) / 2 else -it / 2 }.filter { it in -left..right }
        val x0 = r.centerX() - unit / 2 + layerOffset()[0]
        val bottom = r.top + layerOffset()[1] - 17 * density
        return key.more.mapIndexed { i, more ->
            val x = x0 + order[i % cols] * unit
            val y = bottom - (i / cols + 1) * cellH
            RectF(x, y, x + unit, y + cellH) to more
        }
    }

    /** [onChoose]: TalkBack's panel, whose alternates are typed by a double tap rather than by lifting */
    private fun showPanel(panel: List<Pair<RectF, Layout.Key>>, chosen: Int, onChoose: ((Int) -> Unit)? = null) {
        val frame = RectF(panel.minOf { it.first.left } - 2 * px, panel.minOf { it.first.top } - 2 * px,
            panel.maxOf { it.first.right } + 3 * px, panel.maxOf { it.first.bottom } + 3 * px)
        popups.showPanel(frame, panel.map { it.first to (if (shift != Shift.OFF) it.second.label.uppercase() else it.second.label) }, chosen, onChoose)
    }

    /** A key's face in its cell, the space between rows below it, its top a little above the cell's */
    private fun face(r: RectF) =
        keyFace(Box(r.left, r.top, r.right, r.bottom), density, textScale).let { RectF(it.left, it.top, it.right, it.bottom) }

    /** The key, a row taller upwards, its label in the part above the key */
    private fun showPreview(cell: Cell) {
        val f = face(cell.rect).apply { offset(layerOffset()[0], layerOffset()[1]) }
        popups.showPreview(RectF(f.left, f.top - rowHeight, f.right, f.bottom), shown(cell.key), f.top - rowHeight / 2)
    }

    /** This view's top left in the popup layer's coordinates: it moves in one-handed and floating mode */
    private fun layerOffset(): FloatArray {
        val mine = IntArray(2).also { getLocationInWindow(it) }
        val layer = IntArray(2).also { popups.getLocationInWindow(it) }
        return floatArrayOf((mine[0] - layer[0]).toFloat(), (mine[1] - layer[1]).toFloat())
    }

    // --- Accessibility: each key is a virtual view labelled with what it types or does ---

    private fun description(key: Layout.Key): String = when (key.code) {
        Code.SHIFT -> context.getString(when (shift) {
            Shift.OFF -> R.string.key_shift; Shift.ON -> R.string.key_shift_on; Shift.LOCKED -> R.string.key_caps_lock
        })
        Code.DELETE -> context.getString(R.string.key_delete)
        Code.SYMBOLS -> context.getString(R.string.key_symbols)
        Code.SYMBOLS2 -> context.getString(R.string.key_more_symbols)
        Code.DIGITS -> context.getString(R.string.key_digits)
        Code.LETTERS -> context.getString(R.string.key_letters)
        Code.GLOBE -> context.getString(R.string.key_language)
        Code.KEYBOARDS -> context.getString(R.string.key_pick_keyboard)
        Code.SPACE -> context.getString(R.string.key_space)
        Code.ENTER -> context.getString(when (enter) {
            FieldKind.Enter.NEWLINE, FieldKind.Enter.CUSTOM -> R.string.key_enter
            FieldKind.Enter.SEARCH -> R.string.key_search
            FieldKind.Enter.SEND -> R.string.key_send
            FieldKind.Enter.GO -> R.string.key_go
            FieldKind.Enter.NEXT -> R.string.key_next
            FieldKind.Enter.PREVIOUS -> R.string.key_previous
            FieldKind.Enter.DONE -> R.string.key_done
        })
        else -> shown(key)
    }

    private fun longPressLabel(key: Layout.Key) = when {
        key.code == Code.GLOBE -> R.string.key_pick_keyboard
        key.code == Code.SHIFT -> R.string.key_lock_caps
        key.more.isNotEmpty() -> R.string.key_alternates
        else -> null
    }

    /**
     * TalkBack's long press: the key's alternates in their panel, the first one read out. Each is a
     * double tap away; exploring the keys again closes the panel, as lifting the finger does without it.
     */
    private fun showAlternates(cell: Cell) {
        val panel = panelFor(cell)
        showPanel(panel, -1) { i ->
            popups.clear()
            type(panel[i].second)
        }
        popups.focusChoice(0)
    }

    override fun dispatchHoverEvent(event: MotionEvent): Boolean {
        if (popups.choosing && event.actionMasked == MotionEvent.ACTION_HOVER_ENTER) popups.clear()
        return a11y.dispatchHoverEvent(event) || super.dispatchHoverEvent(event)
    }

    private inner class Accessibility : ExploreByTouchHelper(this@KeyboardView) {
        override fun getVirtualViewAt(x: Float, y: Float) =
            cells.indexOfFirst { it.rect.contains(x, y) }.takeIf { it >= 0 } ?: INVALID_ID

        override fun getVisibleVirtualViews(ids: MutableList<Int>) {
            ids.addAll(cells.indices)
        }

        override fun onPopulateNodeForVirtualView(id: Int, node: AccessibilityNodeInfoCompat) {
            val cell = cells.getOrNull(id)
            if (cell == null) {
                node.contentDescription = ""
                node.setBoundsInParent(android.graphics.Rect())
                return
            }
            node.contentDescription = description(cell.key)
            node.className = "android.widget.Button"
            val r = cell.rect
            node.setBoundsInParent(android.graphics.Rect(r.left.roundToInt(), r.top.roundToInt(), r.right.roundToInt(), r.bottom.roundToInt()))
            node.addAction(AccessibilityNodeInfoCompat.ACTION_CLICK)
            // What a double tap and hold does, as TalkBack announces it
            longPressLabel(cell.key)?.let {
                node.addAction(AccessibilityNodeInfoCompat.AccessibilityActionCompat(AccessibilityNodeInfoCompat.ACTION_LONG_CLICK, context.getString(it)))
            }
        }

        override fun onPopulateEventForVirtualView(id: Int, event: AccessibilityEvent) {
            event.contentDescription = cells.getOrNull(id)?.let { description(it.key) } ?: ""
        }

        override fun onPerformActionForVirtualView(id: Int, action: Int, arguments: Bundle?): Boolean {
            val cell = cells.getOrNull(id) ?: return false
            popups.clear() // TalkBack's alternates, if shown: another key's action leaves them
            return when (action) {
                AccessibilityNodeInfoCompat.ACTION_CLICK -> {
                    when (cell.key.code) {
                        Code.SHIFT -> {
                            setShift(if (shift == Shift.OFF) Shift.ON else Shift.OFF)
                            userShift = shift != Shift.OFF
                        }
                        else -> type(cell.key)
                    }
                    true
                }
                AccessibilityNodeInfoCompat.ACTION_LONG_CLICK -> {
                    when {
                        cell.key.code == Code.GLOBE -> listener.onPickKeyboard()
                        cell.key.code == Code.SHIFT -> {
                            setShift(Shift.LOCKED)
                            userShift = true
                        }
                        cell.key.more.isNotEmpty() -> showAlternates(cell)
                        else -> return false
                    }
                    true
                }
                else -> false
            }
        }
    }
}

/** The narrowest letter key, in dp, any docked keyboard has (split's halves on a 320 dp phone): today's text fits it */
private const val MIN_KEY_WIDTH_DP = 22f

/**
 * The keys' text sizes' share of today's, as today's keyboard sizes them by a key's smaller side: 1 on any
 * docked keyboard (as tall as [Mode.MIN_HEIGHT] or taller, keys [MIN_KEY_WIDTH_DP] wide or wider), smaller on a
 * floating keyboard resized smaller than that (#283).
 */
internal fun keyTextScale(heightScale: Float, keyWidthDp: Float) =
    minOf(1f, heightScale / Mode.MIN_HEIGHT, keyWidthDp / MIN_KEY_WIDTH_DP)

/** Space beside the keys, and between the bar and the first row */
private const val SIDE_PADDING_DP = 2f
private const val TOP_PADDING_DP = 4.2f

/** A key's cell or face, in px */
internal data class Box(val left: Float, val top: Float, val right: Float, val bottom: Float)

/** The keys' height in px: the space above them and their rows, each [rowHeight] px times its own height */
internal fun keysHeight(rows: List<Layout.Row>, rowHeight: Float, density: Float) =
    TOP_PADDING_DP * density + rowsHeight(rows) * rowHeight

/** The rows' height in rows: the number row is 0.9 of one */
internal fun rowsHeight(rows: List<Layout.Row>) = rows.sumOf { it.height.toDouble() }.toFloat()

/**
 * A page's row height in px: [rowHeight], or taller when its rows come short of [fillRows] rows. With a number
 * row on the letters (the setting, a password or e-mail field), the symbols and digits pages fill its height
 * too, as Gboard's do: a keyboard changing height between pages moves the app above it (#531).
 */
internal fun pageRowHeight(rows: List<Layout.Row>, fillRows: Float, rowHeight: Float): Float {
    val own = rowsHeight(rows)
    return if (own > 0 && own < fillRows) rowHeight * fillRows / own else rowHeight
}

/**
 * The keys' cells, where they are touched, in a view [width] px wide. Split: each half keeps 5 key widths in
 * SPLIT_HALF of the width. A key across the middle is on both halves, whole (g, v, as today's), or cut in two
 * when it is wider than a key (space).
 */
internal fun keyCells(rows: List<Layout.Row>, width: Float, rowHeight: Float, density: Float, split: Boolean): List<Pair<Layout.Key, Box>> {
    val side = SIDE_PADDING_DP * density
    val unit = (width - 2 * side) / 10f
    val half = SPLIT_HALF * (width - 2 * side) / 5f
    fun left(u: Float) = side + if (split) u * half else u * unit
    fun right(u: Float) = width - side - (10 - u) * half
    var y = TOP_PADDING_DP * density
    val out = ArrayList<Pair<Layout.Key, Box>>()
    for (row in rows) {
        val h = row.height * rowHeight
        var u = 0f
        for (key in row.keys) {
            val end = u + key.width
            if (key.code != Layout.Code.GAP) when {
                !split || end <= 5 -> out += key to Box(left(u), y, left(end), y + h)
                u >= 5 -> out += key to Box(right(u), y, right(end), y + h)
                key.width <= 1 -> {
                    out += key to Box(left(u), y, left(end), y + h)
                    out += key to Box(right(u), y, right(end), y + h)
                }
                else -> {
                    out += key to Box(left(u), y, left(5f), y + h)
                    out += key to Box(right(5f), y, right(end), y + h)
                }
            }
            u = end
        }
        y += h
    }
    return out
}

/** The key a finger is on in [cells]: the one under it, between keys and at the edges the nearest; none above or below the view */
internal fun keyAt(cells: List<Box>, x: Float, y: Float, height: Float): Int? {
    if (y < 0 || y > height) return null
    cells.indexOfFirst { x >= it.left && x < it.right && y >= it.top && y < it.bottom }.takeIf { it >= 0 }?.let { return it }
    return cells.indices.minByOrNull {
        val c = cells[it]
        val dx = maxOf(c.left - x, 0f, x - c.right)
        val dy = maxOf(c.top - y, 0f, y - c.bottom)
        dx * dx + dy * dy
    }
}

/**
 * The key a finger held on [keys]' key [from] types instead at [x], [y], a move or where it lifts: the one it is
 * now over, once [slides] says so; null when it keeps its key.
 */
internal fun slidTo(keys: List<Layout.Key>, boxes: List<Box>, from: Int, x: Float, y: Float, height: Float, hysteresis: Float): Int? =
    keyAt(boxes, x, y, height)?.takeIf { it != from && slides(keys[from], boxes[from], keys[it], x, y, hysteresis) }

/**
 * Whether a finger held on [from] (its cell [box]), now at [x], [y] over [to], types [to] instead, as today's
 * sliding key input does (AOSP's PointerTracker.isMajorEnoughMoveToBeOnNewKey): once it is [hysteresis] px past
 * the key's edge. Only text keys follow the finger: Space and Delete swipe, Shift chords, and the other keys keep
 * the key they were pressed on.
 */
internal fun slides(from: Layout.Key, box: Box, to: Layout.Key, x: Float, y: Float, hysteresis: Float): Boolean {
    if (from.code != Layout.Code.TEXT || to.code != Layout.Code.TEXT) return false
    val dx = maxOf(box.left - x, 0f, x - box.right)
    val dy = maxOf(box.top - y, 0f, y - box.bottom)
    return dx * dx + dy * dy >= hysteresis * hysteresis
}

/** Split: each half's share of the width */
internal const val SPLIT_HALF = 0.36f

/** The gaps between keys: a key's face starts this far into its cell, and ends this far before its end (today's 1.5 and 2, #329) */
private const val FACE_LEFT_DP = 0.5f
private const val FACE_RIGHT_DP = 1f
/** Today's face's share of its cell's height, from the cell's top; ours is 8% taller around the same middle (#329) */
private const val FACE_HEIGHT = 0.83f
private const val FACE_GROWTH = 0.08f
/**
 * The most a face grows above and below today's: under the space above the first row, so a tall floating
 * keyboard's first row (rows up to 200 dp in a 1200 dp window) stays inside the view. Docked rows (under 78 dp)
 * grow their full 8%.
 */
private const val FACE_GROWTH_MAX_DP = 4f

/** A key's face in its [cell], the space between rows below it; its top a little above the cell's */
internal fun keyFace(cell: Box, density: Float, textScale: Float): Box {
    val h = (cell.bottom - cell.top) * FACE_HEIGHT
    val middle = cell.top + h / 2
    val grow = minOf(h * FACE_GROWTH / 2, FACE_GROWTH_MAX_DP * density)
    return Box(cell.left + FACE_LEFT_DP * density * textScale, middle - h / 2 - grow,
        cell.right - FACE_RIGHT_DP * density * textScale, middle + h / 2 + grow)
}

/** The letters', icons' and hints' sizes in dp: today's 25, 24 and 12.5, 10% larger (#329) */
internal const val LETTER_DP = 27.5f
private const val ICON_DP = 26.4f
private const val HINT_DP = 13.75f

/** The width inside a keycap's outline and shadow, of a key [keyWidth] px wide with frames of [keyPx] px */
internal fun keycapRoom(keyWidth: Float, density: Float, textScale: Float, keyPx: Float) =
    keyWidth - (FACE_LEFT_DP + FACE_RIGHT_DP) * density * textScale - 3 * keyPx

/**
 * The letters' text sizes by label: [size] px for every one, or smaller by one factor for every one when the
 * widest's ink, in either case ([widthAt] measures it at [size]), is wider than [room] px, as on one-handed's and
 * split's keys and the smallest floating ones. A pixel over is let be: the letter's antialiased edge on the
 * outline (W at 25 dp on a 360 dp phone's keys is 0.03 px over at 420 dpi, 0.9 px at 480).
 */
internal fun letterSizes(labels: Collection<String>, size: Float, room: Float, widthAt: (String) -> Float): Map<String, Float> {
    val widest = labels.maxOf { maxOf(widthAt(it), widthAt(it.uppercase())) }
    val fitted = if (widest > room + 1) size * room / widest else size
    return labels.associateWith { fitted }
}
