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
