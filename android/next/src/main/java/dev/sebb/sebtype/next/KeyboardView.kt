package dev.sebb.sebtype.next

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.os.Bundle
import android.os.SystemClock
import android.view.MotionEvent
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

/**
 * The keys: one View drawn on a Canvas. It lays out a [Layout] page (with the number row over it when
 * asked), draws it in the Picnic look and turns touches into keys: a tap types on release, a long press
 * opens the key's choices, Delete repeats while held, a second finger types the first key at once. Every
 * key is a virtual view with a text label for TalkBack and the emulator checks (uiautomator).
 */
@SuppressLint("ViewConstructor")
class KeyboardView(context: Context, private val popups: PopupLayer, private val listener: Listener) : View(context) {
    interface Listener {
        /** A key: its text (Shift applied) for a text key */
        fun onKey(code: Code, text: String)
        /** A long press on 🌐: the system's keyboard picker */
        fun onPickKeyboard()
    }

    enum class Shift { OFF, ON, LOCKED }

    private val density = resources.displayMetrics.density
    private val px = Picnic.pixel(context).toFloat()
    /** Rows are as far apart as Gboard's (#161): 59 dp */
    private val rowHeight = 59 * density
    private val sidePadding = 3 * density
    private val gapX = 3 * density
    private val gapY = 4.5f * density

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

    private val fonts = Picnic.fonts(context)
    private val label = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER; typeface = fonts.first }
    private val hint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textAlign = Paint.Align.RIGHT; typeface = fonts.first; color = Picnic.MUTED; textSize = 10 * density
    }

    private val a11y = Accessibility()

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

    fun setShift(shift: Shift) {
        if (this.shift == shift) return
        this.shift = shift
        invalidate()
        a11y.invalidateRoot()
    }

    private fun rows(page: Layout?, numberRow: Layout?) =
        (page?.rows.orEmpty() + numberRow?.rows.orEmpty()).sumOf { it.height.toDouble() }.toFloat()

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), ceil(rows(page, numberRow) * rowHeight).toInt())
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) = layoutCells()

    private fun layoutCells() {
        val unit = (width - 2 * sidePadding) / 10f
        var y = 0f
        val out = ArrayList<Cell>()
        for (row in numberRow?.rows.orEmpty() + page?.rows.orEmpty()) {
            val h = row.height * rowHeight
            var x = sidePadding
            for (key in row.keys) {
                val w = key.width * unit
                if (key.code != Code.GAP) out += Cell(key, RectF(x, y, x + w, y + h))
                x += w
            }
            y += h
        }
        cells = out
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
        key.function -> PixelFrame.PINK
        else -> PixelFrame.CREAM
    }

    override fun onDraw(canvas: Canvas) {
        for (cell in cells) {
            val r = cell.rect
            val key = cell.key
            val pressed = pointers.values.any { it.cell === cell }
            val l = r.left + gapX; val t = r.top + gapY; val rr = r.right - gapX; val b = r.bottom - gapY
            val frame = frame(key)
            frame.draw(canvas, l, t, rr, b, px, pressed)
            // The frame's shadow takes its last pixel right and below: the face's middle is up and left of it.
            val cx = (l + rr - px) / 2 + if (pressed) px / 2 else 0f
            val cy = (t + b - px) / 2 + if (pressed) px / 2 else 0f
            val ink = if (frame === PixelFrame.BERRY) Picnic.WHITE else Picnic.INK
            val icon = icon(key)
            when {
                icon != null -> Icons.draw(canvas, icon, cx, cy, min(24 * density, (b - t) * 0.5f), ink)
                key.code == Code.SPACE -> {
                    label.textSize = 13 * density
                    label.color = Picnic.MUTED
                    canvas.drawText(spaceLabel, cx, cy + label.textSize * 0.35f, label)
                }
                else -> {
                    val s = shown(key)
                    label.textSize = (if (s.length > 1) 15 else if (cell.rect.height() < rowHeight) 20 else 23) * density
                    label.color = ink
                    canvas.drawText(s, cx, cy + label.textSize * 0.35f, label)
                }
            }
            key.hint?.let { canvas.drawText(it, rr - 3 * px, t + 2 * px + hint.textSize, hint) }
        }
    }

    // --- Touch ---

    private class Pointer(val cell: Cell, val downAt: Long) {
        var panel: List<Pair<RectF, Layout.Key>>? = null
        var chosen = 0
        /** Shift, held while another key is typed: off again when it is let go */
        var chorded = false
    }

    private val pointers = HashMap<Int, Pointer>()
    private var lastShiftTap = 0L
    private val longPressMs = 350L
    private val repeatStartMs = 400L
    private val repeatMs = 50L

    private val longPress = Runnable { onLongPress() }
    private val repeat = object : Runnable {
        override fun run() {
            if (pointers.values.none { it.cell.key.code == Code.DELETE }) return
            listener.onKey(Code.DELETE, "")
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
                press(e.getPointerId(i), cell)
            }
            MotionEvent.ACTION_MOVE -> for (i in 0 until e.pointerCount) {
                val p = pointers[e.getPointerId(i)] ?: continue
                p.panel?.let { panel ->
                    val x = e.getX(i)
                    val y = e.getY(i) - layerOffsetY()
                    val nearest = panel.indices.minByOrNull {
                        val r = panel[it].first
                        abs(r.centerX() - x) + abs(r.centerY() - y) * 0.5f
                    } ?: 0
                    if (nearest != p.chosen) { p.chosen = nearest; showPanel(p) }
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

    private fun press(id: Int, cell: Cell) {
        val p = Pointer(cell, SystemClock.uptimeMillis())
        pointers[id] = p
        removeCallbacks(longPress)
        when (cell.key.code) {
            Code.SHIFT -> {
                val now = SystemClock.uptimeMillis()
                setShift(when {
                    shift == Shift.ON && now - lastShiftTap < 300 -> Shift.LOCKED
                    shift == Shift.OFF -> Shift.ON
                    else -> Shift.OFF
                })
                lastShiftTap = now
            }
            Code.DELETE -> {
                listener.onKey(Code.DELETE, "")
                postDelayed(repeat, repeatStartMs)
            }
            else -> {
                if (cell.key.code == Code.TEXT) showPreview(cell)
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
            key.code == Code.DELETE -> removeCallbacks(repeat)
            key.code == Code.GLOBE && SystemClock.uptimeMillis() - p.downAt >= longPressMs -> {}
            else -> type(key)
        }
        if (pointers.isEmpty()) popups.clear()
        invalidate()
    }

    private fun type(key: Layout.Key) {
        val text = text(key)
        // One Shift types one capital; locked, it stays. Held, it lasts until it is let go.
        if (key.code == Code.TEXT && shift == Shift.ON && pointers.values.none { it.cell.key.code == Code.SHIFT }) setShift(Shift.OFF)
        listener.onKey(key.code, text)
        pointers.values.filter { it.cell.key.code == Code.SHIFT }.forEach { it.chorded = true }
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
        val unit = (width - 2 * sidePadding) / 10f
        val perRow = min(key.more.size, 8)
        val rows = (key.more.size + perRow - 1) / perRow
        val cellH = rowHeight * 0.85f
        val panelW = perRow * unit + 4 * px
        val panelH = rows * cellH + 4 * px
        val offset = layerOffsetY()
        val r = p.cell.rect
        val left = (r.centerX() - unit / 2 - 2 * px).coerceIn(0f, width - panelW)
        val bottom = r.top + gapY + offset
        val top = bottom - panelH
        p.panel = key.more.mapIndexed { i, more ->
            val x = left + 2 * px + (i % perRow) * unit
            val y = top + 2 * px + (i / perRow) * cellH
            RectF(x, y, x + unit, y + cellH) to more
        }
        p.chosen = 0
        showPanel(p)
    }

    private fun showPanel(p: Pointer) {
        val panel = p.panel ?: return
        val frame = RectF(panel.minOf { it.first.left } - 2 * px, panel.minOf { it.first.top } - 2 * px,
            panel.maxOf { it.first.right } + 3 * px, panel.maxOf { it.first.bottom } + 3 * px)
        popups.showPanel(frame, panel.map { it.first to (if (shift != Shift.OFF) it.second.label.uppercase() else it.second.label) }, p.chosen)
    }

    private fun showPreview(cell: Cell) {
        val r = cell.rect
        val offset = layerOffsetY()
        val w = r.width() - 2 * gapX + 4 * density
        val h = (r.height() - 2 * gapY) * 1.25f
        val bottom = r.top + gapY + offset
        popups.showPreview(RectF(r.centerX() - w / 2, bottom - h, r.centerX() + w / 2, bottom), shown(cell.key))
    }

    /** This view's top in the popup layer's coordinates */
    private fun layerOffsetY(): Float {
        val mine = IntArray(2).also { getLocationInWindow(it) }
        val layer = IntArray(2).also { popups.getLocationInWindow(it) }
        return (mine[1] - layer[1]).toFloat()
    }

    // --- Accessibility: each key is a virtual view labelled with what it types or does ---

    private fun description(key: Layout.Key): String = when (key.code) {
        Code.SHIFT -> context.getString(when (shift) {
            Shift.OFF -> R.string.key_shift; Shift.ON -> R.string.key_shift_on; Shift.LOCKED -> R.string.key_caps_lock
        })
        Code.DELETE -> context.getString(R.string.key_delete)
        Code.SYMBOLS -> context.getString(R.string.key_symbols)
        Code.SYMBOLS2 -> context.getString(R.string.key_more_symbols)
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

    override fun dispatchHoverEvent(event: MotionEvent) = a11y.dispatchHoverEvent(event) || super.dispatchHoverEvent(event)

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
            if (cell.key.more.isNotEmpty()) node.addAction(AccessibilityNodeInfoCompat.ACTION_LONG_CLICK)
        }

        override fun onPopulateEventForVirtualView(id: Int, event: AccessibilityEvent) {
            event.contentDescription = cells.getOrNull(id)?.let { description(it.key) } ?: ""
        }

        override fun onPerformActionForVirtualView(id: Int, action: Int, arguments: Bundle?): Boolean {
            val cell = cells.getOrNull(id) ?: return false
            return when (action) {
                AccessibilityNodeInfoCompat.ACTION_CLICK -> {
                    when (cell.key.code) {
                        Code.SHIFT -> setShift(if (shift == Shift.OFF) Shift.ON else Shift.OFF)
                        else -> type(cell.key)
                    }
                    true
                }
                AccessibilityNodeInfoCompat.ACTION_LONG_CLICK -> {
                    if (cell.key.code == Code.GLOBE) listener.onPickKeyboard()
                    else cell.key.more.firstOrNull()?.let { type(it) }
                    true
                }
                else -> false
            }
        }
    }
}
