package dev.sebb.sebtype.next

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.view.MotionEvent
import android.view.View
import dev.sebb.sebtype.next.Icons.Icon

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
        /** Floating: the keyboard's share of the width */
        const val FLOATING_WIDTH = 0.85f
    }
}

/**
 * Keyboard Modes, in place of the keys: the four modes as tiles (the one in use pink), then the height with
 * − and + around it.
 */
@SuppressLint("ViewConstructor")
class ModesPanel(context: Context, private val texts: Texts, private val listener: Listener) : ItemsView(context, vertical = true) {
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
    private var mode = Mode.STANDARD
    private var height = 1f

    private enum class Kind { HEIGHT, SHORTER, TALLER }

    fun show(mode: Mode, height: Float) {
        this.mode = mode
        this.height = height
        rebuild()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) = rebuild()

    private fun rebuild() {
        if (width == 0) return
        val pad = 10 * density
        val gap = 10 * density
        val out = ArrayList<Item>()
        var y = 8 * density
        val tile = (width - 2 * pad - 3 * gap) / 4
        val tileH = 92 * density
        Mode.entries.forEachIndexed { i, m ->
            val l = pad + i * (tile + gap)
            out += Item(RectF(l, y, l + tile, y + tileH), texts[m.label], "android.widget.RadioButton", checked = m == mode, tag = m)
        }
        y += tileH + 16 * density
        val row = 56 * density
        out += Item(RectF(pad, y, width - pad, y + row), "${texts[R.string.mode_height]} ${(height * 100).toInt()}%", "android.widget.TextView", tag = Kind.HEIGHT)
        out += Item(RectF(pad, y, pad + row, y + row), texts[R.string.mode_shorter], "android.widget.Button", tag = Kind.SHORTER)
        out += Item(RectF(width - pad - row, y, width - pad, y + row), texts[R.string.mode_taller], "android.widget.Button", tag = Kind.TALLER)
        y += row + 16 * density
        // The buttons over the height's card: a tap finds them first.
        setItems(out.sortedBy { it.tag == Kind.HEIGHT }, y)
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
                fill.color = if (tag == mode) Picnic.PINK else Picnic.CREAM
                canvas.drawRoundRect(r, radius, radius, fill)
                Icons.draw(canvas, tag.icon, r.centerX(), r.top + 34 * density, 26 * density, Picnic.INK)
                canvas.drawText(item.label, r.centerX(), r.top + 70 * density, label)
            }
            Kind.HEIGHT -> {
                fill.color = Picnic.CREAM
                canvas.drawRoundRect(r, radius, radius, fill)
                canvas.drawText(item.label, r.centerX(), r.centerY() + label.textSize * 0.35f, label)
            }
            Kind.SHORTER, Kind.TALLER -> Icons.draw(canvas, if (tag == Kind.TALLER) Icon.PLUS else Icon.MINUS,
                r.centerX(), r.centerY(), 22 * density, if (canTap(tag as Kind)) Picnic.INK else Picnic.FADED)
        }
    }

    private fun canTap(kind: Kind) =
        if (kind == Kind.TALLER) height < Mode.MAX_HEIGHT - 0.001f else height > Mode.MIN_HEIGHT + 0.001f
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
