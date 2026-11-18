package dev.sebb.sebtype

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.view.MotionEvent
import android.view.View
import androidx.core.view.ViewCompat
import androidx.core.view.accessibility.AccessibilityNodeInfoCompat
import androidx.core.view.accessibility.AccessibilityNodeInfoCompat.AccessibilityActionCompat
import androidx.customview.widget.ExploreByTouchHelper
import dev.sebb.sebtype.Icons.Icon
import kotlin.math.hypot
import kotlin.math.roundToInt

/** How the keyboard sits on the screen (#53 B5), and its height; kept per orientation, as today's */
enum class Mode(val label: Int, val icon: Icon) {
    STANDARD(R.string.mode_standard, Icon.STANDARD),
    ONE_HANDED(R.string.mode_one_handed, Icon.ONE_HANDED),
    SPLIT(R.string.mode_split, Icon.SPLIT),
    FLOATING(R.string.mode_floating, Icon.FLOATING);

    companion object {
        const val MIN_HEIGHT = 0.8f
        const val MAX_HEIGHT = 1.3f
        const val HEIGHT_STEP = 0.05f
        /** One-handed: the keys' share of the width */
        const val ONE_HANDED_WIDTH = 0.8f
        /** Floating: the keyboard's share of the width before it is resized */
        const val FLOATING_WIDTH = 0.85f
        /** Floating: the narrowest it gets, as today's (three 48 dp keys) */
        const val FLOATING_MIN_WIDTH_DP = 144f
        /** Floating: four rows' height, as today's: at least this, and at most the larger of this and ⅔ of the window */
        const val FLOATING_MIN_HEIGHT_DP = 96f
        const val FLOATING_MAX_HEIGHT_DP = 384f
        /** Floating: TalkBack's Wider and Narrower, as shares of the window's width */
        const val WIDTH_STEP = 0.05f
    }
}

/**
 * Keyboard Modes, a row over the keys as today's (which stay to type on): the four modes as tabs, the one in
 * use on pink. Resize Keyboard (the bar's button) puts the height, with − and + around it, in their place.
 */
@SuppressLint("ViewConstructor")
class ModesPanel(context: Context, private val texts: Texts, private val listener: Listener) : ItemsView(context, vertical = false) {
    interface Listener {
        fun onMode(mode: Mode)
        fun onHeight(by: Float)
    }

    private val density = resources.displayMetrics.density
    private val label = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 14 * density
        color = Picnic.INK
        textAlign = Paint.Align.CENTER
    }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    /** The modes' names' text size, as wide as their tabs allow */
    private var modeText = 14 * density
    private var mode = Mode.STANDARD
    private var scale = 1f
    var resizing = false
        private set

    private enum class Kind { HEIGHT, SHORTER, TALLER }

    fun show(mode: Mode, height: Float, resizing: Boolean) {
        this.mode = mode
        this.scale = height
        this.resizing = resizing
        rebuild()
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) =
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), (64 * density).toInt())

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) = rebuild()

    private fun rebuild() {
        if (width == 0) return
        val pad = 8 * density
        val h = scale
        val top = 4 * density
        val bottom = height - 4 * density
        val out = ArrayList<Item>()
        if (resizing) {
            // − and + on either side of the height's card
            val button = (bottom - top) * 1.4f
            out += Item(RectF(pad, top, pad + button, bottom), texts[R.string.mode_shorter], "android.widget.Button", fixed = true, tag = Kind.SHORTER)
            out += Item(RectF(pad + button + pad, top, width - 2 * pad - button, bottom), "${texts[R.string.mode_height]} ${(h * 100).toInt()}%",
                "android.widget.TextView", fixed = true, tag = Kind.HEIGHT)
            out += Item(RectF(width - pad - button, top, width - pad, bottom), texts[R.string.mode_taller], "android.widget.Button", fixed = true, tag = Kind.TALLER)
            setItems(out, 0f)
            return
        }
        val tab = (width - 2 * pad) / Mode.entries.size
        // A narrow keyboard (floating, resized, #283) shrinks the modes' names, all alike, to fit their tabs.
        label.textSize = 14 * density
        modeText = Mode.entries.minOf { label.textSize * minOf(1f, (tab - 4 * density) / label.measureText(texts[it.label])) }
        Mode.entries.forEachIndexed { i, m ->
            val l = pad + i * tab
            out += Item(RectF(l, top, l + tab, bottom), texts[m.label], "android.widget.RadioButton", fixed = true, checked = m == mode, tag = m)
        }
        setItems(out, 0f)
    }

    override fun onTap(item: Item) {
        when (val tag = item.tag) {
            is Mode -> listener.onMode(tag)
            Kind.SHORTER -> listener.onHeight(-Mode.HEIGHT_STEP)
            Kind.TALLER -> listener.onHeight(Mode.HEIGHT_STEP)
        }
    }

    override fun drawItem(canvas: Canvas, item: Item) {
        val r = item.rect
        val radius = 15 * density
        when (val tag = item.tag) {
            is Mode -> {
                if (tag == mode) {
                    fill.color = Picnic.PINK
                    canvas.drawRoundRect(r.left + 3 * density, r.top, r.right - 3 * density, r.bottom, radius, radius, fill)
                }
                Icons.draw(canvas, tag.icon, r.centerX(), r.top + 20 * density, 22 * density, Picnic.INK)
                label.textSize = modeText
                canvas.drawText(item.label, r.centerX(), r.bottom - 9 * density, label)
            }
            Kind.HEIGHT -> {
                fill.color = Picnic.CREAM
                canvas.drawRoundRect(r, radius, radius, fill)
                label.textSize = 14 * density
                canvas.drawText(item.label, r.centerX(), r.centerY() + label.textSize * 0.35f, label)
            }
            Kind.SHORTER, Kind.TALLER -> Icons.draw(canvas, if (tag == Kind.TALLER) Icon.PLUS else Icon.MINUS,
                r.centerX(), r.centerY(), 22 * density, if (canTap(tag as Kind)) Picnic.INK else Picnic.FADED)
        }
    }

    private fun canTap(kind: Kind) =
        if (kind == Kind.TALLER) scale < Mode.MAX_HEIGHT - 0.001f else scale > Mode.MIN_HEIGHT + 0.001f
}

/**
 * One-handed mode's strip beside the keys: ⇄ moves the keys to the other side, the full-width icon goes
 * back to the standard keyboard.
 */
@SuppressLint("ViewConstructor")
class SideStrip(context: Context, private val texts: Texts, private val onSwap: () -> Unit, private val onStandard: () -> Unit) :
    ItemsView(context, vertical = true) {
    private val density = resources.displayMetrics.density

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        val mid = h / 2f
        setItems(listOf(
            Item(RectF(0f, mid - 64 * density, w.toFloat(), mid - 8 * density), texts[R.string.mode_swap], "android.widget.Button", tag = Icon.SWAP),
            Item(RectF(0f, mid + 8 * density, w.toFloat(), mid + 64 * density), texts[R.string.mode_standard], "android.widget.Button", tag = Icon.STANDARD),
        ), h.toFloat())
    }

    override fun onTap(item: Item) = if (item.tag == Icon.SWAP) onSwap() else onStandard()

    override fun drawItem(canvas: Canvas, item: Item) =
        Icons.draw(canvas, item.tag as Icon, item.rect.centerX(), item.rect.centerY(), 24 * density, Picnic.INK)
}

/** Floating mode's handle over the bar: dragging it moves the keyboard by (dx, dy). */
@SuppressLint("ViewConstructor")
class DragHandle(context: Context, private val texts: Texts, private val onDrag: (Float, Float) -> Unit, private val onDone: () -> Unit) : View(context) {
    private val density = resources.displayMetrics.density
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Picnic.MUTED }
    private var lastX = 0f
    private var lastY = 0f

    init {
        contentDescription = texts[R.string.mode_move]
    }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) =
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), (20 * density).toInt())

    override fun onDraw(canvas: Canvas) {
        val w = 40 * density
        canvas.drawRoundRect(width / 2f - w / 2, height / 2f - 2 * density, width / 2f + w / 2, height / 2f + 2 * density,
            2 * density, 2 * density, fill)
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> { lastX = e.rawX; lastY = e.rawY }
            MotionEvent.ACTION_MOVE -> {
                onDrag(e.rawX - lastX, e.rawY - lastY)
                lastX = e.rawX; lastY = e.rawY
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> onDone()
        }
        return true
    }
}

/**
 * Floating mode's Resize Keyboard, as today's (KeyboardResizers): a frame over the keyboard, red while the
 * keyboard is held at a limit. Its corner, dragged, sets the width and height together (#283); a drag
 * anywhere else moves the keyboard; Reset and Apply in the middle, Apply ending it. For TalkBack the corner
 * has the actions Wider, Narrower, Taller and Shorter.
 */
@SuppressLint("ViewConstructor")
class ResizeFrame(context: Context, private val texts: Texts, private val listener: Listener) : View(context) {
    interface Listener {
        /** The corner dragged by (dx, dy) px; false when the keyboard stopped at a limit */
        fun onResize(dx: Float, dy: Float): Boolean
        /** One step wider (1) or narrower (-1), taller (1) or shorter (-1) */
        fun onResizeStep(wider: Int, taller: Int)
        fun onMove(dx: Float, dy: Float)
        /** A drag ended: the size and place are kept */
        fun onResizeDone()
        fun onResetSize()
        fun onApplySize()
    }

    private enum class Part { CORNER, RESET, APPLY, MOVE }

    private val density = resources.displayMetrics.density
    private val shade = Paint().apply { color = Picnic.CREAM; alpha = 128 }
    private val border = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 3 * density }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 15 * density
        textAlign = Paint.Align.CENTER
        typeface = Picnic.fonts(context).first
    }
    private val radius = 24 * density
    private val reset = RectF()
    private val apply = RectF()
    private var held: Part? = null
    private var atLimit = false
    private var lastX = 0f
    private var lastY = 0f
    private val a11y = Accessibility()

    init {
        ViewCompat.setAccessibilityDelegate(this, a11y)
    }

    // The keyboard's height, not the room it may have: its parent measures it again to the keyboard's.
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) = setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec),
        if (MeasureSpec.getMode(heightMeasureSpec) == MeasureSpec.EXACTLY) MeasureSpec.getSize(heightMeasureSpec) else 0)

    /** Where the label's middle is */
    private var labelY = 0f

    /**
     * Reset and Apply side by side in the middle, as today's, while each gets [MIN_BUTTON_DP]; on a keyboard
     * resized narrower (down to [Mode.FLOATING_MIN_WIDTH_DP]) one over the other.
     */
    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        val pad = 8 * density
        val tall = 40 * density
        val side = (w - 2 * pad - 2 * pad) / 2
        if (side >= MIN_BUTTON_DP * density) {
            val button = minOf(96 * density, side)
            val y = h / 2f + pad
            reset.set(w / 2f - pad - button, y, w / 2f - pad, y + tall)
            apply.set(w / 2f + pad, y, w / 2f + pad + button, y + tall)
            labelY = h / 2f - 2 * pad
        } else {
            val button = minOf(96 * density, w - 2 * pad)
            val y = h / 2f - tall / 2
            reset.set(w / 2f - button / 2, y, w / 2f + button / 2, y + tall)
            apply.set(reset.left, reset.bottom + pad, reset.right, reset.bottom + pad + tall)
            labelY = y - 2 * pad
        }
        // The label in the width there is
        text.textSize = 15 * density
        val wide = text.measureText(texts[R.string.mode_resize_corner])
        if (wide > w - 2 * pad) text.textSize *= (w - 2 * pad) / wide
        // The corner at the screen's edge (a keyboard as wide as the window) is in gesture navigation's Back
        // area: a drag there resizes instead of going back.
        if (Build.VERSION.SDK_INT >= 29) systemGestureExclusionRects = listOf(Rect(w - (2 * radius).toInt(), h - (2 * radius).toInt(), w, h))
        a11y.invalidateRoot()
    }

    /** TalkBack's focus on the corner: the keys under the frame are hidden from it while it shows. */
    fun focusCorner() {
        a11y.getAccessibilityNodeProvider(this)?.performAction(0, AccessibilityNodeInfoCompat.ACTION_ACCESSIBILITY_FOCUS, null)
    }

    private companion object {
        /** A button's narrowest, side by side */
        const val MIN_BUTTON_DP = 72f
    }

    private fun corner() = RectF(width - 2 * radius, height - 2 * radius, width.toFloat(), height.toFloat())

    override fun onDraw(canvas: Canvas) {
        val line = if (atLimit) Picnic.LIMIT else Picnic.BERRY
        val r = 4 * density
        canvas.drawRoundRect(0f, 0f, width.toFloat(), height.toFloat(), r, r, shade)
        border.color = line
        val inset = border.strokeWidth / 2
        canvas.drawRoundRect(inset, inset, width - inset, height - inset, r, r, border)
        // The corner: a circle cut by the frame, as today's handles
        canvas.save()
        canvas.clipRect(0, 0, width, height)
        fill.color = if (atLimit) Picnic.LIMIT else if (held == Part.CORNER) Picnic.BERRY_HIGH else Picnic.BERRY
        canvas.drawCircle(width.toFloat(), height.toFloat(), radius, fill)
        canvas.restore()
        text.color = Picnic.INK
        canvas.drawText(texts[R.string.mode_resize_corner], width / 2f, labelY, text)
        for ((rect, label) in listOf(reset to R.string.mode_reset, apply to R.string.mode_apply)) {
            fill.color = Picnic.CREAM
            canvas.drawRoundRect(rect, 15 * density, 15 * density, fill)
            text.color = Picnic.BERRY
            canvas.drawText(texts[label], rect.centerX(), rect.centerY() + text.textSize * 0.35f, text)
        }
    }

    // The buttons first: on a narrow keyboard Apply reaches the corner's touch area.
    private fun partAt(x: Float, y: Float) = when {
        reset.contains(x, y) -> Part.RESET
        apply.contains(x, y) -> Part.APPLY
        hypot(width - x, height - y) < 2 * radius -> Part.CORNER
        else -> Part.MOVE
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        // In the screen's coordinates: the frame moves and grows under the finger.
        val dx = e.rawX - lastX
        val dy = e.rawY - lastY
        lastX = e.rawX; lastY = e.rawY
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> { held = partAt(e.x, e.y); invalidate() }
            MotionEvent.ACTION_MOVE -> when (held) {
                Part.CORNER -> { atLimit = !listener.onResize(dx, dy); invalidate() }
                Part.MOVE -> listener.onMove(dx, dy)
                else -> {}
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                val part = held
                held = null
                atLimit = false
                invalidate()
                when (part) {
                    Part.CORNER, Part.MOVE -> listener.onResizeDone()
                    Part.RESET -> if (e.actionMasked == MotionEvent.ACTION_UP && reset.contains(e.x, e.y)) listener.onResetSize()
                    Part.APPLY -> if (e.actionMasked == MotionEvent.ACTION_UP && apply.contains(e.x, e.y)) listener.onApplySize()
                    null -> {}
                }
            }
        }
        return true
    }

    override fun dispatchHoverEvent(event: MotionEvent) = a11y.dispatchHoverEvent(event) || super.dispatchHoverEvent(event)

    private inner class Accessibility : ExploreByTouchHelper(this@ResizeFrame) {
        private val parts = listOf(Part.CORNER, Part.RESET, Part.APPLY)
        /** The corner's actions: their ids, labels, and the step each takes */
        private val steps = listOf(
            Triple(R.id.resize_wider, R.string.mode_wider, 1 to 0),
            Triple(R.id.resize_narrower, R.string.mode_narrower, -1 to 0),
            Triple(R.id.resize_taller, R.string.mode_taller, 0 to 1),
            Triple(R.id.resize_shorter, R.string.mode_shorter, 0 to -1),
        )

        override fun getVirtualViewAt(x: Float, y: Float) = parts.indexOf(partAt(x, y)).takeIf { it >= 0 } ?: INVALID_ID

        override fun getVisibleVirtualViews(ids: MutableList<Int>) {
            ids += parts.indices
        }

        override fun onPopulateNodeForVirtualView(id: Int, node: AccessibilityNodeInfoCompat) {
            val (rect, label) = when (parts[id]) {
                Part.CORNER -> corner() to R.string.mode_resize_corner
                Part.RESET -> reset to R.string.mode_reset
                else -> apply to R.string.mode_apply
            }
            node.contentDescription = texts[label]
            node.className = "android.widget.Button"
            node.setBoundsInParent(Rect(rect.left.roundToInt(), rect.top.roundToInt(), rect.right.roundToInt(), rect.bottom.roundToInt()))
            if (parts[id] == Part.CORNER) for ((action, name, _) in steps) node.addAction(AccessibilityActionCompat(action, texts[name]))
            else node.addAction(AccessibilityNodeInfoCompat.ACTION_CLICK)
        }

        override fun onPerformActionForVirtualView(id: Int, action: Int, arguments: Bundle?): Boolean {
            when (parts.getOrNull(id)) {
                Part.CORNER -> {
                    val (wider, taller) = steps.firstOrNull { it.first == action }?.third ?: return false
                    listener.onResizeStep(wider, taller)
                }
                Part.RESET -> if (action == AccessibilityNodeInfoCompat.ACTION_CLICK) listener.onResetSize() else return false
                Part.APPLY -> if (action == AccessibilityNodeInfoCompat.ACTION_CLICK) listener.onApplySize() else return false
                else -> return false
            }
            return true
        }
    }
}
