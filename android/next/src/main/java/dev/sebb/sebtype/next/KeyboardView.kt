package dev.sebb.sebtype.next

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
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
import dev.sebb.sebtype.next.Icons.Icon
import dev.sebb.sebtype.next.Layout.Code
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
 * opens the key's choices, Delete repeats while held, a second finger types the first key at once. Every
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
    private val sidePadding = 2 * density
    /** Space between the bar and the first row */
    private val topPadding = 4.2f * density

    private var page: Layout? = null
    private var numberRow: Layout? = null
    var shift = Shift.OFF
        private set
    /** The space bar's label: the language's name */
    var spaceLabel = ""
        set(value) { field = value; invalidate() }
    /** $, or ¥ in 中文 and 日本語 */
    private var currency = "$"
    var enter = FieldKind.Enter.NEWLINE
        set(value) { field = value; invalidate(); a11y.invalidateRoot() }

    private class Cell(val key: Layout.Key, val rect: RectF)
    private var cells = emptyList<Cell>()
    /** The keys' text sizes' share of today's: [keyTextScale] of the keys as laid out */
    private var textScale = 1f

    private val fonts = Picnic.fonts(context)
    private val label = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER; typeface = fonts.first }
    private val hint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.RIGHT; typeface = fonts.first; color = Picnic.MUTED; textSize = 12.5f * density
    }

    private val a11y = Accessibility()

    private companion object {
        /** A key's vibration, as short as a tap */
        const val VIBRATE_MS = 12L
        /** A row's height in dp at the default height */
        const val ROW = 59.3f
        /** Hints are drawn while the text is at least this share of today's size */
        const val MIN_HINT_SCALE = 0.6f
        /** Split: each half's share of the width */
        const val SPLIT_HALF = 0.36f
        /** Space swipe: key widths per character the cursor moves */
        const val CURSOR_STEP = 0.4f
    }

    init {
        ViewCompat.setAccessibilityDelegate(this, a11y)
        id = R.id.keyboard
    }

    fun setPage(page: Layout, numberRow: Layout?, currency: String) {
        if (this.page === page && this.numberRow === numberRow && this.currency == currency) return
        val heightChanged = rows(this.page, this.numberRow) != rows(page, numberRow)
        this.page = page
        this.numberRow = numberRow
        this.currency = currency
        cancelTouches()
        if (heightChanged) requestLayout() else layoutCells()
        invalidate()
        a11y.invalidateRoot()
    }

    /** Whether the last letter was typed with Shift the user turned on (or locked), not the field's capital */
    var typedWithUserShift = false
        private set
    private var userShift = false

    fun setShift(shift: Shift) {
        userShift = false
        if (this.shift == shift) return
        this.shift = shift
        invalidate()
        a11y.invalidateRoot()
    }

    private fun rows(page: Layout?, numberRow: Layout?) =
        (page?.rows.orEmpty() + numberRow?.rows.orEmpty()).sumOf { it.height.toDouble() }.toFloat()

    /** The keys' height in px at [scale] (a [heightScale]), and the scale that gives them [height] px */
    fun heightAt(scale: Float) = topPadding + rows(page, numberRow) * ROW * density * scale
    fun scaleFor(height: Float) = (height - topPadding) / (rows(page, numberRow) * ROW * density)
    /** The height scale at which four rows are [dp] dp: today's floating keyboard sets its height as four rows' */
    fun scaleForFourRows(dp: Float) = dp / (4 * ROW)

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), ceil(topPadding + rows(page, numberRow) * rowHeight).toInt())
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) = layoutCells()

    private fun layoutCells() {
        val unit = (width - 2 * sidePadding) / 10f
        // Split: each half keeps 5 key widths in SPLIT_HALF of the width. A key across the middle is on both
        // halves, whole (g, v, as today's), or cut in two when it is wider than a key (space).
        val half = SPLIT_HALF * (width - 2 * sidePadding) / 5f
        fun left(u: Float) = sidePadding + if (split) u * half else u * unit
        fun right(u: Float) = width - sidePadding - (10 - u) * half
        var y = topPadding
        val out = ArrayList<Cell>()
        for (row in numberRow?.rows.orEmpty() + page?.rows.orEmpty()) {
            val h = row.height * rowHeight
            var u = 0f
            for (key in row.keys) {
                val end = u + key.width
                if (key.code != Code.GAP) when {
                    !split || end <= 5 -> out += Cell(key, RectF(left(u), y, left(end), y + h))
                    u >= 5 -> out += Cell(key, RectF(right(u), y, right(end), y + h))
                    key.width <= 1 -> {
                        out += Cell(key, RectF(left(u), y, left(end), y + h))
                        out += Cell(key, RectF(right(u), y, right(end), y + h))
                    }
                    else -> {
                        out += Cell(key, RectF(left(u), y, left(5f), y + h))
                        out += Cell(key, RectF(right(5f), y, right(end), y + h))
                    }
                }
                u = end
            }
            y += h
        }
        cells = out
        textScale = keyTextScale(heightScale, (if (split) half else unit) / density)
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
        Code.GLOBE -> Icon.GLOBE
        Code.ENTER -> when (enter) {
            FieldKind.Enter.NEWLINE -> Icon.ENTER
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
            frame.draw(canvas, l, t, rr, b, px, pressed)
            // The frame's shadow takes its last pixel right and below: the face's middle is up and left of it.
            val cx = (l + rr - px) / 2 + if (pressed) px / 2 else 0f
            val cy = (t + b - px) / 2 + if (pressed) px / 2 else 0f
            val ink = if (frame === PixelFrame.BERRY) Picnic.WHITE else Picnic.INK
            val icon = icon(key)
            when {
                icon != null -> Icons.draw(canvas, icon, cx, cy, min(24 * density, (b - t) * 0.5f), ink)
                key.code == Code.SPACE && key.label.isBlank() -> {
                    label.textSize = 13 * density * textScale
                    // Split's halves of the space bar are narrow: the label shrinks to fit, as today's does
                    val room = rr - l - 12 * density
                    val w = label.measureText(spaceLabel)
                    if (w > room) label.textSize *= room / w
                    label.color = Picnic.FADED
                    canvas.drawText(spaceLabel, cx, cy + label.textSize * 0.35f, label)
                }
                key.label.contains('\n') -> {
                    // The numbers page's key: its digits small, in two lines
                    label.textSize = 11 * density * textScale
                    label.color = ink
                    val lines = key.label.split('\n')
                    lines.forEachIndexed { i, line ->
                        canvas.drawText(line, cx, cy + label.textSize * (0.35f + 1.1f * (i - (lines.size - 1) / 2f)), label)
                    }
                }
                else -> {
                    val s = shown(key)
                    label.textSize = when {
                        s.length > 1 -> 13f
                        cell.rect.height() < rowHeight -> 20f
                        // The small punctuation is drawn larger, as today's keyboard does
                        s in ",.、。" -> 45f
                        else -> 25f
                    } * density * textScale
                    // A key narrower than its letter (W on the narrowest floating keyboard) shrinks it to fit.
                    val room = rr - l - 2 * px
                    val w = label.measureText(s)
                    if (w > room) label.textSize *= room / w
                    label.color = ink
                    canvas.drawText(s, cx, cy + label.textSize * 0.35f, label)
                }
            }
            // Hints shrink with the letters; too small to read, they go.
            hint.textSize = 12.5f * density * textScale
            if (hints && textScale >= MIN_HINT_SCALE) key.hint?.let { canvas.drawText(it, rr - 3 * px, t + 2 * px + hint.textSize * 0.9f, hint) }
        }
    }

    // --- Touch ---

    private class Pointer(val cell: Cell, val downAt: Long, val downX: Float, val downY: Float) {
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
    private var lastShiftTap = 0L
    /** The settings' long-press time and key popup ([dev.sebb.sebtype.next.data.Prefs]) */
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

    private fun cellAt(x: Float, y: Float): Cell? =
        cells.firstOrNull { it.rect.contains(x, y) } ?: cells.minByOrNull {
            // Between keys and at the edges, the nearest key
            val dx = maxOf(it.rect.left - x, 0f, x - it.rect.right)
            val dy = maxOf(it.rect.top - y, 0f, y - it.rect.bottom)
            dx * dx + dy * dy
        }?.takeIf { y >= 0 && y <= height }

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
                if (p.panel == null) swipe(p)
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
                val id = e.getPointerId(e.actionIndex)
                pointers[id]?.let { release(id, it) }
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
        typedWithUserShift = userShift && shift != Shift.OFF
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

    /** A key's face in its cell: its outline starts at the cell's top, the space between rows below it. */
    private fun face(r: RectF) = RectF(r.left + 1.5f * density, r.top, r.right - 2 * density, r.top + r.height() * 0.83f)

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
        Code.SPACE -> context.getString(R.string.key_space)
        Code.ENTER -> context.getString(when (enter) {
            FieldKind.Enter.NEWLINE -> R.string.key_enter
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
                        Code.SHIFT -> setShift(if (shift == Shift.OFF) Shift.ON else Shift.OFF)
                        else -> type(cell.key)
                    }
                    true
                }
                AccessibilityNodeInfoCompat.ACTION_LONG_CLICK -> {
                    when {
                        cell.key.code == Code.GLOBE -> listener.onPickKeyboard()
                        cell.key.code == Code.SHIFT -> setShift(Shift.LOCKED)
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
