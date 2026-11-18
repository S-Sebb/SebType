package dev.sebb.sebtype

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Rect
import android.os.Bundle
import android.view.MotionEvent
import android.view.View
import androidx.core.view.ViewCompat
import androidx.core.view.accessibility.AccessibilityNodeInfoCompat
import androidx.customview.widget.ExploreByTouchHelper
import kotlin.math.roundToInt

/**
 * Drawn over the whole keyboard window, the floating strip above the bar included, and never touched: a
 * key's preview while it is pressed and the long-press panel (#28: both in the pixel font). The keyboard
 * owns the touch and tells this layer what to show, in the layer's coordinates. TalkBack's long press shows
 * the panel with its alternates as virtual views here, each typed by a double tap (#283).
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

    /** TalkBack's panel: a double tap on alternate i calls this */
    private var onChoose: ((Int) -> Unit)? = null
    val choosing get() = onChoose != null
    private val a11y = Accessibility()

    init {
        importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
        ViewCompat.setAccessibilityDelegate(this, a11y)
    }

    /** [labelY]: the middle of the label */
    fun showPreview(rect: RectF, label: String, labelY: Float) {
        preview = Triple(rect, label, labelY)
        invalidate()
    }

    /** [onChoose]: TalkBack's panel, read out choice by choice; a double tap on one calls it */
    fun showPanel(frame: RectF, cells: List<Pair<RectF, String>>, selected: Int, onChoose: ((Int) -> Unit)? = null) {
        panel = Triple(frame, cells, selected)
        preview = null
        accessible(onChoose)
        invalidate()
    }

    fun clear() {
        if (preview == null && panel == null) return
        preview = null
        panel = null
        accessible(null)
        invalidate()
    }

    private fun accessible(onChoose: ((Int) -> Unit)?) {
        if (onChoose == null && this.onChoose == null) return
        this.onChoose = onChoose
        importantForAccessibility = if (onChoose != null) IMPORTANT_FOR_ACCESSIBILITY_YES else IMPORTANT_FOR_ACCESSIBILITY_NO
        a11y.invalidateRoot()
    }

    /** TalkBack's focus to choice [i], which it reads out */
    fun focusChoice(i: Int) {
        ViewCompat.getAccessibilityNodeProvider(this)?.performAction(i, AccessibilityNodeInfoCompat.ACTION_ACCESSIBILITY_FOCUS, null)
    }

    override fun dispatchHoverEvent(event: MotionEvent) = a11y.dispatchHoverEvent(event) || super.dispatchHoverEvent(event)

    private inner class Accessibility : ExploreByTouchHelper(this@PopupLayer) {
        private val cells get() = if (choosing) panel?.second.orEmpty() else emptyList()

        override fun getVirtualViewAt(x: Float, y: Float) =
            cells.indexOfFirst { it.first.contains(x, y) }.takeIf { it >= 0 } ?: INVALID_ID

        override fun getVisibleVirtualViews(ids: MutableList<Int>) {
            ids.addAll(cells.indices)
        }

        override fun onPopulateNodeForVirtualView(id: Int, node: AccessibilityNodeInfoCompat) {
            val (r, label) = cells.getOrNull(id) ?: run {
                node.contentDescription = ""
                node.setBoundsInParent(Rect())
                return
            }
            node.contentDescription = label
            node.className = "android.widget.Button"
            node.setBoundsInParent(Rect(r.left.roundToInt(), r.top.roundToInt(), r.right.roundToInt(), r.bottom.roundToInt()))
            node.addAction(AccessibilityNodeInfoCompat.ACTION_CLICK)
        }

        override fun onPerformActionForVirtualView(id: Int, action: Int, arguments: Bundle?): Boolean {
            if (action != AccessibilityNodeInfoCompat.ACTION_CLICK || id !in cells.indices) return false
            onChoose?.invoke(id)
            return true
        }
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
