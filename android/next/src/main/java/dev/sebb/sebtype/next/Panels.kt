package dev.sebb.sebtype.next

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF

/**
 * The candidates after those the bar shows (up to 128 in all), in place of the keys, scrolling down; a tap
 * picks one. As today's keyboard: a cream panel, columns 58 dp wide with lines between them.
 */
@SuppressLint("ViewConstructor")
class CandidateGrid(context: Context, private val onPick: (Int) -> Unit) : ItemsView(context, vertical = true) {
    private val density = resources.displayMetrics.density
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Picnic.fonts(context).first
        textSize = 18 * density
        color = Picnic.INK
        textAlign = Paint.Align.CENTER
    }
    private val line = Paint().apply { color = Picnic.OUTLINE }
    private var candidates = emptyList<String>()
    private var from = 0

    /** [from]: the first one not in the bar */
    fun show(candidates: List<String>, from: Int) {
        this.candidates = candidates
        this.from = from
        rebuild()
    }

    override fun onDraw(canvas: Canvas) {
        canvas.drawColor(Picnic.CREAM)
        super.onDraw(canvas)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) = rebuild()

    private fun rebuild() {
        if (width == 0) return
        val col = 58 * density
        val columns = maxOf(1, (width / col).toInt())
        val rowH = 40 * density
        val out = ArrayList<Item>()
        var c = 0
        var y = 0f
        // A long candidate takes as many columns as it needs.
        for (i in from until candidates.size) {
            val span = minOf(columns, kotlin.math.ceil((text.measureText(candidates[i]) + 20 * density) / col).toInt())
            if (c + span > columns) { c = 0; y += rowH }
            out += Item(RectF(c * col, y, (c + span) * col, y + rowH), candidates[i], "android.widget.TextView", tag = i)
            c += span
        }
        setItems(out, y + rowH)
    }

    override fun onTap(item: Item) = onPick(item.tag as Int)

    override fun drawItem(canvas: Canvas, item: Item) {
        val r = item.rect
        if (r.right < width - density) canvas.drawRect(r.right - density, r.centerY() - 12.5f * density, r.right, r.centerY() + 12.5f * density, line)
        canvas.drawText(item.label, r.centerX(), r.centerY() + text.textSize * 0.35f, text)
    }
}

/**
 * The menu the bar's › opens, in place of the keys: 中文's 简/繁 switch (#36) and the incognito tile (#31),
 * in today's keyboard's action panel look (rounded cream cards). Stage 4's action bar takes its place.
 */
@SuppressLint("ViewConstructor")
class MenuPanel(context: Context, private val listener: Listener) : ItemsView(context, vertical = true) {
    interface Listener {
        fun onTraditional(on: Boolean)
        fun onIncognito(on: Boolean)
    }

    private val density = resources.displayMetrics.density
    private val bold = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 17 * density
        color = Picnic.INK
        typeface = android.graphics.Typeface.DEFAULT_BOLD
    }
    private val regular = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 15 * density
        color = Picnic.INK
        textAlign = Paint.Align.CENTER
    }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 2 * density }
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
        val pad = 10 * density
        val gap = 16 * density
        val out = ArrayList<Item>()
        var y = 8 * density
        traditional?.let { on ->
            val h = 56 * density
            val mid = width / 2f
            out += Item(RectF(pad, y, mid - 28 * density, y + h), "简体", "android.widget.TextView", tag = Kind.SIMPLIFIED)
            out += Item(RectF(mid - 28 * density, y, width - pad, y + h), "繁體", "android.widget.Switch", checked = on, tag = Kind.TRADITIONAL)
            y += h + gap
        }
        val tile = (width - 2 * pad - 2 * gap) / 3
        out += Item(RectF(pad, y, pad + tile, y + 92 * density), context.getString(R.string.incognito), "android.widget.Switch",
            checked = incognito, tag = Kind.INCOGNITO)
        y += 92 * density + gap
        setItems(out, y)
    }

    override fun onTap(item: Item) {
        when (item.tag) {
            Kind.SIMPLIFIED -> listener.onTraditional(false)
            Kind.TRADITIONAL -> listener.onTraditional(traditional != true)
            Kind.INCOGNITO -> listener.onIncognito(!incognito)
        }
    }

    private fun card(canvas: Canvas, l: Float, t: Float, r: Float, b: Float, color: Int = Picnic.CREAM) =
        canvas.drawRoundRect(l, t, r, b, 15 * density, 15 * density, fill.apply { this.color = color })

    override fun drawItem(canvas: Canvas, item: Item) {
        val r = item.rect
        val cy = r.centerY()
        when (item.tag) {
            // One card for 简体 [switch] 繁體, centred: drawn with its left part.
            Kind.SIMPLIFIED -> {
                card(canvas, r.left, r.top, width - r.left, r.bottom)
                bold.typeface = if (traditional == true) android.graphics.Typeface.DEFAULT else android.graphics.Typeface.DEFAULT_BOLD
                canvas.drawText(item.label, width / 2f - 40 * density - bold.measureText(item.label), cy + bold.textSize * 0.35f, bold)
            }
            Kind.TRADITIONAL -> {
                bold.typeface = if (item.checked == true) android.graphics.Typeface.DEFAULT_BOLD else android.graphics.Typeface.DEFAULT
                canvas.drawText(item.label, width / 2f + 40 * density, cy + bold.textSize * 0.35f, bold)
                drawSwitch(canvas, width / 2f, cy, item.checked == true)
            }
            Kind.INCOGNITO -> {
                card(canvas, r.left, r.top, r.right, r.bottom, if (incognito) Picnic.PINK else Picnic.CREAM)
                Icons.draw(canvas, Icons.Icon.INCOGNITO, r.centerX(), r.top + 34 * density, 24 * density, Picnic.INK)
                canvas.drawText(item.label, r.centerX(), r.top + 70 * density, regular)
            }
        }
    }

    /** A round switch centred at ([cx], [cy]): a tan track with a brown knob left (off), brown with a cream knob right (on) */
    private fun drawSwitch(canvas: Canvas, cx: Float, cy: Float, on: Boolean) {
        val w = 52 * density
        val h = 32 * density
        val l = cx - w / 2
        fill.color = if (on) Picnic.OUTLINE else Picnic.LINE
        canvas.drawRoundRect(l, cy - h / 2, l + w, cy + h / 2, h / 2, h / 2, fill)
        stroke.color = Picnic.OUTLINE
        canvas.drawRoundRect(l + density, cy - h / 2 + density, l + w - density, cy + h / 2 - density, h / 2, h / 2, stroke)
        fill.color = if (on) Picnic.CREAM else Picnic.OUTLINE
        canvas.drawCircle(if (on) l + w - h / 2 else l + h / 2, cy, if (on) 12 * density else 8 * density, fill)
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
 * 中文's pinyin as it is typed, floating over the app just above the bar in a grey box (as today's keyboard
 * shows it): Rime's composition never goes into the field. Its space is kept while empty, so the keys don't
 * move.
 */
class PreeditStrip(context: Context) : android.view.View(context) {
    private val density = resources.displayMetrics.density
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 16 * density
        color = android.graphics.Color.BLACK
    }
    private val box = Paint().apply { color = Picnic.PREEDIT }
    var preedit = ""
        set(value) {
            if (field == value) return
            field = value
            contentDescription = value
            invalidate()
        }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) =
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), (24 * density).toInt())

    override fun onDraw(canvas: Canvas) {
        if (preedit.isEmpty()) return
        canvas.drawRect(0f, 0f, text.measureText(preedit) + 8 * density, height.toFloat(), box)
        canvas.drawText(preedit, 3 * density, height / 2f + text.textSize * 0.35f, text)
    }
}
