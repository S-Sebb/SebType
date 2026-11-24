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
 * the panel with its alternates as virtual views here, each typed by a double tap (#283). The held globe's
 * language list (#526) is a panel too, its rows left-aligned and the current language marked.
 */
class PopupLayer(context: Context) : View(context) {
    private val px = Picnic.pixel(context).toFloat()
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Picnic.INK
        textAlign = Paint.Align.CENTER
        typeface = Picnic.fonts(context).second
    }
    private val mark = Paint()
    private val selected = PixelFrame(Picnic.BERRY, Picnic.BERRY_HIGH, Picnic.BERRY_LOW, shadow = false)

    private var preview: Triple<RectF, String, Float>? = null
    /** The long-press panel: its frame, each choice's cell and label, and the selected one */
    private var panel: Triple<RectF, List<Pair<RectF, String>>, Int>? = null
    /** A list panel: its rows left-aligned, [marked] (the current language; -1: none) marked */
    private var list = false
    private var marked = -1
    /** What TalkBack reads for each choice, where it isn't the label */
    private var descriptions: List<String>? = null

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

    /**
     * [onChoose]: TalkBack's panel, read out choice by choice ([descriptions], or the labels); a double tap on one
     * calls it. [list]: a list, its rows left-aligned, row [marked] marked.
     */
    fun showPanel(frame: RectF, cells: List<Pair<RectF, String>>, selected: Int, onChoose: ((Int) -> Unit)? = null,
                  list: Boolean = false, marked: Int = -1, descriptions: List<String>? = null) {
        panel = Triple(frame, cells, selected)
        this.list = list
        this.marked = marked
        this.descriptions = descriptions
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
            node.contentDescription = descriptions?.getOrNull(id) ?: label
            node.className = "android.widget.Button"
            node.isSelected = id == marked
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
                val y = r.centerY() + text.textSize * 0.35f
                if (!list) return@forEachIndexed canvas.drawText(label, r.centerX(), y, text)
                // A list's row: a pixel square marks the current one, the labels start after its column
                if (i == marked) {
                    mark.color = if (i == chosen) Picnic.WHITE else Picnic.BERRY
                    val s = listMark(r.height())
                    canvas.drawRect(r.left + s, r.centerY() - s / 2, r.left + 2 * s, r.centerY() + s / 2, mark)
                }
                text.textAlign = Paint.Align.LEFT
                canvas.drawText(label, r.left + listIndent(r.height()), y, text)
                text.textAlign = Paint.Align.CENTER
            }
        }
    }
}

/** A list row's mark, a square [listMark] wide one square in from the row's left */
internal fun listMark(rowHeight: Float) = rowHeight * 0.2f

/** Where a list row's label starts: after the mark, a square's space beyond it */
internal fun listIndent(rowHeight: Float) = 3 * listMark(rowHeight)
