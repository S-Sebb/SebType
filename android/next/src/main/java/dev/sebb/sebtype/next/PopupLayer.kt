package dev.sebb.sebtype.next

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.view.View

/**
 * Drawn over the whole keyboard window, the floating strip above the bar included, and never touched: a
 * key's preview while it is pressed and the long-press panel (#28: both in the pixel font). The keyboard
 * owns the touch and tells this layer what to show, in the layer's coordinates.
 */
class PopupLayer(context: Context) : View(context) {
    private val px = Picnic.pixel(context).toFloat()
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Picnic.INK
        textAlign = Paint.Align.CENTER
        typeface = Picnic.fonts(context).second
    }
    private val selected = PixelFrame(Picnic.BERRY, Picnic.BERRY_HIGH, Picnic.BERRY_LOW, shadow = false)

    private var preview: Triple<RectF, String, Float>? = null
    /** The long-press panel: its frame, each choice's cell and label, and the selected one */
    private var panel: Triple<RectF, List<Pair<RectF, String>>, Int>? = null

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
    }

    /** [labelY]: the middle of the label */
    fun showPreview(rect: RectF, label: String, labelY: Float) {
        preview = Triple(rect, label, labelY)
        invalidate()
    }

    fun showPanel(frame: RectF, cells: List<Pair<RectF, String>>, selected: Int) {
        panel = Triple(frame, cells, selected)
        preview = null
        invalidate()
    }

    fun clear() {
        if (preview == null && panel == null) return
        preview = null
        panel = null
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        preview?.let { (r, label, y) ->
            PixelFrame.CREAM.draw(canvas, r.left, r.top, r.right, r.bottom, px)
            text.textSize = r.width() * 0.45f
            text.color = Picnic.INK
            canvas.drawText(label, r.centerX() - px / 2, y + text.textSize * 0.35f, text)
        }
        panel?.let { (frame, cells, chosen) ->
            PixelFrame.CREAM.draw(canvas, frame.left, frame.top, frame.right, frame.bottom, px)
            cells.forEachIndexed { i, (r, label) ->
                if (i == chosen) selected.draw(canvas, r.left, r.top, r.right, r.bottom, px)
                text.textSize = r.height() * 0.45f
                text.color = if (i == chosen) Picnic.WHITE else Picnic.INK
                canvas.drawText(label, r.centerX(), r.centerY() + text.textSize * 0.35f, text)
            }
        }
    }
}
