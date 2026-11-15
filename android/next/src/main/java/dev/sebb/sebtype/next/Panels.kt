package dev.sebb.sebtype.next

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF

/** All the candidates (up to 128), in place of the keys, scrolling down; a tap picks one. */
@SuppressLint("ViewConstructor")
class CandidateGrid(context: Context, private val onPick: (Int) -> Unit) : ItemsView(context, vertical = true) {
    private val density = resources.displayMetrics.density
    private val px = Picnic.pixel(context).toFloat()
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Picnic.fonts(context).first
        textSize = 18 * density
        color = Picnic.INK
        textAlign = Paint.Align.CENTER
    }
    private var candidates = emptyList<String>()

    fun show(candidates: List<String>) {
        this.candidates = candidates
        rebuild()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) = rebuild()

    private fun rebuild() {
        if (width == 0) return
        val pad = 6 * density
        val rowH = 52 * density
        val minW = (width - 2 * pad) / 6
        val out = ArrayList<Item>()
        var x = pad
        var y = pad
        // Rows fill left to right; a row's cells then stretch to its full width.
        var row = ArrayList<Pair<Int, Float>>()
        fun flush() {
            if (row.isEmpty()) return
            val spare = (width - pad - x) / row.size
            var cx = pad
            for ((i, w) in row) {
                out += Item(RectF(cx, y, cx + w + spare, y + rowH), candidates[i], "android.widget.TextView", tag = i)
                cx += w + spare
            }
            row = ArrayList()
            x = pad
            y += rowH
        }
        candidates.forEachIndexed { i, c ->
            val w = maxOf(minW, text.measureText(c) + 24 * density).coerceAtMost(width - 2 * pad)
            if (x + w > width - pad) flush()
            row += i to w
            x += w
        }
        flush()
        setItems(out, y + pad)
    }

    override fun onTap(item: Item) = onPick(item.tag as Int)

    override fun drawItem(canvas: Canvas, item: Item) {
        val r = item.rect
        val frame = if (item.tag == 0) PixelFrame.PINK else PixelFrame.CREAM
        frame.draw(canvas, r.left + 2 * density, r.top + 3 * density, r.right - 2 * density, r.bottom - 3 * density, px)
        canvas.drawText(item.label, r.centerX() - px / 2, r.centerY() + text.textSize * 0.35f - px / 2, text)
    }
}

/**
 * The menu the bar's › opens, in place of the keys: 中文's 简/繁 switch (#36) and the incognito switch (#31).
 * Stage 4's action bar takes its place.
 */
@SuppressLint("ViewConstructor")
class MenuPanel(context: Context, private val listener: Listener) : ItemsView(context, vertical = true) {
    interface Listener {
        fun onTraditional(on: Boolean)
        fun onIncognito(on: Boolean)
    }

    private val density = resources.displayMetrics.density
    private val px = Picnic.pixel(context).toFloat()
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Picnic.fonts(context).first
        textSize = 17 * density
        color = Picnic.INK
    }
    private var traditional: Boolean? = null
    private var incognito = false

    private enum class Kind { SIMPLIFIED, TRADITIONAL, INCOGNITO }

    /** [traditional]: null outside 中文, where the switch isn't shown */
    fun show(traditional: Boolean?, incognito: Boolean) {
        this.traditional = traditional
        this.incognito = incognito
        rebuild()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) = rebuild()

    private fun rebuild() {
        if (width == 0) return
        val pad = 12 * density
        val rowH = 56 * density
        val out = ArrayList<Item>()
        var y = pad
        traditional?.let { on ->
            out += Item(RectF(pad, y, width / 2f, y + rowH), "简体", "android.widget.TextView", tag = Kind.SIMPLIFIED)
            out += Item(RectF(width / 2f, y, width - pad, y + rowH), "繁體", "android.widget.Switch", checked = on, tag = Kind.TRADITIONAL)
            y += rowH + pad
        }
        out += Item(RectF(pad, y, width - pad, y + rowH), context.getString(R.string.incognito), "android.widget.Switch",
            checked = incognito, tag = Kind.INCOGNITO)
        y += rowH + pad
        setItems(out, y)
    }

    override fun onTap(item: Item) {
        when (item.tag) {
            Kind.SIMPLIFIED -> listener.onTraditional(false)
            Kind.TRADITIONAL -> listener.onTraditional(traditional != true)
            Kind.INCOGNITO -> listener.onIncognito(!incognito)
        }
    }

    override fun drawItem(canvas: Canvas, item: Item) {
        val r = item.rect
        val cy = r.centerY() + text.textSize * 0.35f
        when (item.tag) {
            // One framed row for 简体 [switch] 繁體: the frame is drawn with its left half.
            Kind.SIMPLIFIED -> {
                PixelFrame.CREAM.draw(canvas, r.left, r.top, width - r.left, r.bottom, px)
                canvas.drawText(item.label, r.left + 16 * density, cy, text)
            }
            Kind.TRADITIONAL -> {
                val w = text.measureText(item.label)
                canvas.drawText(item.label, r.right - 16 * density - w, cy, text)
                drawSwitch(canvas, r.left - 26 * density, r.centerY(), item.checked == true)
            }
            Kind.INCOGNITO -> {
                PixelFrame.CREAM.draw(canvas, r.left, r.top, r.right, r.bottom, px)
                Icons.draw(canvas, Icons.Icon.INCOGNITO, r.left + 30 * density, r.centerY(), 24 * density, Picnic.INK)
                canvas.drawText(item.label, r.left + 54 * density, cy, text)
                drawSwitch(canvas, r.right - 52 * density, r.centerY(), item.checked == true)
            }
        }
    }

    /** A pixel switch, [x] its left edge: a framed track with the knob left (off) or right on berry (on) */
    private fun drawSwitch(canvas: Canvas, x: Float, cy: Float, on: Boolean) {
        val w = 52 * density
        val h = 28 * density
        val track = if (on) PixelFrame.BERRY else PixelFrame.PINK
        track.draw(canvas, x, cy - h / 2, x + w, cy + h / 2, px, pressed = true)
        val k = h - 6 * px
        val kx = if (on) x + w - 3 * px - k else x + 2 * px
        PixelFrame.CREAM.draw(canvas, kx, cy - h / 2 + 2 * px, kx + k, cy - h / 2 + 2 * px + k, px)
    }
}

/** The bar and the keys sit on the picnic cloth. */
class ClothPanel(context: Context) : android.widget.LinearLayout(context) {
    private val cloth = Picnic.cloth(context)

    init {
        orientation = VERTICAL
        setWillNotDraw(false)
    }

    override fun onDraw(canvas: Canvas) = canvas.drawPaint(cloth)
}

/**
 * 中文's pinyin as it is typed, floating over the app just above the bar (as today's keyboard shows it):
 * Rime's composition never goes into the field. Its space is kept while empty, so the keys don't move.
 */
class PreeditStrip(context: Context) : android.view.View(context) {
    private val density = resources.displayMetrics.density
    private val px = Picnic.pixel(context).toFloat()
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Picnic.fonts(context).first
        textSize = 15 * density
        color = Picnic.INK
    }
    var preedit = ""
        set(value) {
            if (field == value) return
            field = value
            contentDescription = value
            invalidate()
        }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) =
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), (30 * density).toInt())

    override fun onDraw(canvas: Canvas) {
        if (preedit.isEmpty()) return
        val w = text.measureText(preedit) + 20 * density
        PixelFrame.CREAM.draw(canvas, 4 * density, 2 * density, 4 * density + w, height - 2 * density, px)
        canvas.drawText(preedit, 14 * density, height / 2f + text.textSize * 0.35f - px / 2, text)
    }
}
