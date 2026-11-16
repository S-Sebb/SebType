package dev.sebb.sebtype.next

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Rect
import android.graphics.RectF
import android.os.Bundle
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.accessibility.AccessibilityEvent
import android.widget.OverScroller
import androidx.core.view.ViewCompat
import androidx.core.view.accessibility.AccessibilityNodeInfoCompat
import androidx.customview.widget.ExploreByTouchHelper
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * A row or grid of tappable items drawn on a Canvas: the candidate bar, the expanded candidates and the menu.
 * Items scroll along one axis, except fixed ones (the bar's buttons); a tap picks one, a long press may do
 * more (an emoji's skin tones). Each item is a
 * virtual view labelled with its text, so TalkBack reads it and the emulator checks find it.
 */
@SuppressLint("ViewConstructor")
abstract class ItemsView(context: Context, private val vertical: Boolean) : View(context) {
    class Item(
        /** Where it is, in content coordinates (fixed items: in the view's) */
        val rect: RectF,
        val label: String,
        /** The class TalkBack and uiautomator see: a candidate is a TextView, a control a Button */
        val role: String,
        val fixed: Boolean = false,
        val checked: Boolean? = null,
        val tag: Any? = null,
    )

    protected var items = emptyList<Item>()
        private set
    /** How far the content reaches along the scroll axis */
    private var extent = 0f
    protected var scroll = 0f
        private set
    private val scroller = OverScroller(context)
    private val slop = ViewConfiguration.get(context).scaledTouchSlop
    private val minFling = ViewConfiguration.get(context).scaledMinimumFlingVelocity
    private var velocity: VelocityTracker? = null
    private var downX = 0f
    private var downY = 0f
    private var lastPos = 0f
    private var dragging = false
    private var longPressed = false
    private val longPress = Runnable {
        itemAt(downX, downY)?.let { longPressed = onLongPress(it) }
    }
    private val a11y = Accessibility()

    init {
        ViewCompat.setAccessibilityDelegate(this, a11y)
    }

    protected abstract fun onTap(item: Item)
    protected abstract fun drawItem(canvas: Canvas, item: Item)
    /** A long press on [item]; true if it did something, and the touch then doesn't tap */
    protected open fun onLongPress(item: Item) = false

    /** Scrolls to [pos] along the scroll axis */
    protected fun scrollTo(pos: Float) {
        scroller.forceFinished(true)
        scroll = pos.coerceIn(0f, maxScroll())
        invalidate()
        a11y.invalidateRoot()
    }

    /** New items; [keepScroll] keeps the scroll position, otherwise it goes back to the start. */
    protected fun setItems(items: List<Item>, extent: Float, keepScroll: Boolean = false) {
        this.items = items
        this.extent = extent
        if (!keepScroll) {
            scroller.forceFinished(true)
            scroll = 0f
        }
        scroll = scroll.coerceIn(0f, maxScroll())
        invalidate()
        a11y.invalidateRoot()
    }

    /** The part of the view the scrolling items show in, along the scroll axis */
    protected open fun viewport() = if (vertical) height.toFloat() else width.toFloat()
    private fun maxScroll() = (extent - viewport()).coerceAtLeast(0f)

    override fun onDraw(canvas: Canvas) {
        if (scroller.computeScrollOffset()) {
            scroll = scroller.currX.toFloat().takeIf { !vertical } ?: scroller.currY.toFloat()
            postInvalidateOnAnimation()
        }
        canvas.save()
        clipScrolling(canvas)
        if (vertical) canvas.translate(0f, origin() - scroll) else canvas.translate(origin() - scroll, 0f)
        items.filter { !it.fixed }.forEach { drawItem(canvas, it) }
        canvas.restore()
        items.filter { it.fixed }.forEach { drawItem(canvas, it) }
    }

    /** Where the scrolling items start in the view, along the scroll axis */
    protected open fun origin() = 0f

    /** Clips the scrolling items to their part of the view */
    protected open fun clipScrolling(canvas: Canvas) {}

    /** An item's place in the view's coordinates */
    protected fun onScreen(item: Item): RectF =
        if (item.fixed) item.rect
        else RectF(item.rect).apply { if (vertical) offset(0f, origin() - scroll) else offset(origin() - scroll, 0f) }

    private fun itemAt(x: Float, y: Float) = items.firstOrNull { it.fixed && it.rect.contains(x, y) }
        ?: items.firstOrNull { !it.fixed && onScreen(it).contains(x, y) && inViewport(x, y) }

    private fun inViewport(x: Float, y: Float) = (if (vertical) y else x) - origin() in 0f..viewport()

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        val pos = if (vertical) e.y else e.x
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                scroller.forceFinished(true)
                downX = e.x; downY = e.y; lastPos = pos
                dragging = false
                longPressed = false
                postDelayed(longPress, ViewConfiguration.getLongPressTimeout().toLong())
                velocity = VelocityTracker.obtain().apply { addMovement(e) }
            }
            MotionEvent.ACTION_MOVE -> {
                velocity?.addMovement(e)
                if (!dragging && abs(if (vertical) e.y - downY else e.x - downX) > slop) {
                    dragging = true
                    removeCallbacks(longPress)
                }
                if (dragging) {
                    scroll = (scroll + lastPos - pos).coerceIn(0f, maxScroll())
                    invalidate()
                }
                lastPos = pos
            }
            MotionEvent.ACTION_UP -> {
                removeCallbacks(longPress)
                val v = velocity
                if (dragging && v != null) {
                    v.addMovement(e)
                    v.computeCurrentVelocity(1000)
                    val speed = -(if (vertical) v.yVelocity else v.xVelocity)
                    if (abs(speed) > minFling) {
                        val max = maxScroll().roundToInt()
                        if (vertical) scroller.fling(0, scroll.roundToInt(), 0, speed.roundToInt(), 0, 0, 0, max)
                        else scroller.fling(scroll.roundToInt(), 0, speed.roundToInt(), 0, 0, max, 0, 0)
                        postInvalidateOnAnimation()
                    }
                    a11y.invalidateRoot()
                } else if (!dragging && !longPressed) itemAt(e.x, e.y)?.let { onTap(it) }
                velocity?.recycle(); velocity = null
            }
            MotionEvent.ACTION_CANCEL -> { removeCallbacks(longPress); velocity?.recycle(); velocity = null }
        }
        return true
    }

    override fun dispatchHoverEvent(event: MotionEvent) = a11y.dispatchHoverEvent(event) || super.dispatchHoverEvent(event)

    private fun visible(item: Item) = item.fixed || onScreen(item).let {
        val o = origin()
        if (vertical) it.bottom > o && it.top < o + viewport() else it.right > o && it.left < o + viewport()
    }

    private inner class Accessibility : ExploreByTouchHelper(this@ItemsView) {
        override fun getVirtualViewAt(x: Float, y: Float) = itemAt(x, y)?.let { items.indexOf(it) } ?: INVALID_ID

        override fun getVisibleVirtualViews(ids: MutableList<Int>) {
            items.forEachIndexed { i, item -> if (visible(item)) ids += i }
        }

        override fun onPopulateNodeForVirtualView(id: Int, node: AccessibilityNodeInfoCompat) {
            val item = items.getOrNull(id)
            if (item == null) {
                node.contentDescription = ""
                node.setBoundsInParent(Rect())
                return
            }
            node.text = item.label
            node.className = item.role
            val r = onScreen(item)
            // A half-shown item at the edge: only its shown part
            if (!item.fixed) {
                val o = origin()
                if (vertical) { r.top = r.top.coerceAtLeast(o); r.bottom = r.bottom.coerceAtMost(o + viewport()) }
                else { r.left = r.left.coerceAtLeast(o); r.right = r.right.coerceAtMost(o + viewport()) }
            }
            node.setBoundsInParent(Rect(r.left.roundToInt(), r.top.roundToInt(), r.right.roundToInt(), r.bottom.roundToInt()))
            item.checked?.let { node.isCheckable = true; node.isChecked = it }
            node.addAction(AccessibilityNodeInfoCompat.ACTION_CLICK)
            node.addAction(AccessibilityNodeInfoCompat.ACTION_LONG_CLICK)
        }

        override fun onPopulateEventForVirtualView(id: Int, event: AccessibilityEvent) {
            event.contentDescription = items.getOrNull(id)?.label ?: ""
        }

        override fun onPerformActionForVirtualView(id: Int, action: Int, arguments: Bundle?): Boolean {
            val item = items.getOrNull(id) ?: return false
            return when (action) {
                AccessibilityNodeInfoCompat.ACTION_CLICK -> { onTap(item); true }
                AccessibilityNodeInfoCompat.ACTION_LONG_CLICK -> onLongPress(item)
                else -> false
            }
        }
    }
}
