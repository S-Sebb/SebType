package dev.sebb.sebtype.next

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import dev.sebb.sebtype.next.Icons.Icon

/**
 * The bar over the keys. From the left: the menu button (›), 日本語's あ/ア chip (#38), the incognito badge
 * (#31), then the candidates, scrolling sideways, the first on a pink chip (#28); the button at the right end
 * opens all of them. While 中文 sets itself up, or after its setup failed, a notice takes the candidates' place.
 */
@SuppressLint("ViewConstructor")
class CandidateBar(context: Context, private val listener: Listener) : ItemsView(context, vertical = false) {
    interface Listener {
        fun onCandidate(index: Int)
        fun onMenu()
        fun onChip()
        fun onIncognito()
        fun onExpand()
        fun onNotice()
    }

    enum class Badge { NONE, FIELD, TOGGLE }

    private val density = resources.displayMetrics.density
    private val px = Picnic.pixel(context).toFloat()
    private val barHeight = (48 * density).toInt()
    private val button = 40 * density
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Picnic.fonts(context).first
        textSize = 18 * density
        color = Picnic.INK
    }
    private val small = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Picnic.fonts(context).first
        textSize = 14 * density
        color = Picnic.MUTED
    }
    private val chipFrame = PixelFrame(Picnic.CREAM, Picnic.WHITE, Picnic.LINE)

    private var candidates = emptyList<String>()
    private var chip: String? = null
    private var badge = Badge.NONE
    private var notice: String? = null
    var menuOpen = false
        private set
    var expanded = false
        private set
    /** Where the scrolling candidates start: after the fixed controls on the left */
    private var start = 0f

    private object Role {
        const val CANDIDATE = "android.widget.TextView"
        const val BUTTON = "android.widget.Button"
    }

    private enum class Kind { MENU, CHIP, BADGE, NOTICE, EXPAND }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) =
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), barHeight)

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) = rebuild(false)

    fun show(candidates: List<String>, chip: String?, badge: Badge, notice: String?, menuOpen: Boolean, expanded: Boolean) {
        val same = candidates == this.candidates
        if (same && chip == this.chip && badge == this.badge && notice == this.notice &&
            menuOpen == this.menuOpen && expanded == this.expanded) return
        this.candidates = candidates
        this.chip = chip
        this.badge = badge
        this.notice = notice
        this.menuOpen = menuOpen
        this.expanded = expanded
        rebuild(keepScroll = same)
    }

    private fun rebuild(keepScroll: Boolean) {
        if (width == 0) return
        val h = height.toFloat()
        val out = ArrayList<Item>()
        var x = 0f
        out += Item(RectF(x, 0f, x + button, h), context.getString(if (menuOpen) R.string.close_menu else R.string.open_menu),
            Role.BUTTON, fixed = true, tag = Kind.MENU)
        x += button
        chip?.let {
            out += Item(RectF(x, 0f, x + button, h), it, Role.BUTTON, fixed = true, tag = Kind.CHIP)
            x += button
        }
        if (badge != Badge.NONE) {
            val label = context.getString(if (badge == Badge.TOGGLE) R.string.incognito_on else R.string.incognito_field)
            out += Item(RectF(x, 0f, x + button, h), label, Role.BUTTON, fixed = true, tag = Kind.BADGE)
            x += button
        }
        start = x
        val end = width - button
        var extent = 0f
        val notice = notice
        if (notice != null) {
            out += Item(RectF(x, 0f, width.toFloat(), h), notice, Role.CANDIDATE, tag = Kind.NOTICE)
        } else {
            val pad = 12 * density
            var cx = start
            candidates.forEachIndexed { i, c ->
                val w = text.measureText(c) + 2 * pad
                out += Item(RectF(cx, 0f, cx + w, h), c, Role.CANDIDATE, tag = i)
                cx += w
            }
            extent = cx - start
            if (candidates.isNotEmpty() || expanded)
                out += Item(RectF(end, 0f, width.toFloat(), h),
                    context.getString(if (expanded) R.string.fewer_candidates else R.string.more_candidates),
                    Role.BUTTON, fixed = true, tag = Kind.EXPAND)
        }
        // Scrolling items are placed from 0; the view draws them after the controls.
        setItems(out.map { if (it.fixed) it else Item(RectF(it.rect).apply { offset(-start, 0f) }, it.label, it.role, tag = it.tag) },
            extent, keepScroll)
    }

    override fun viewport() = width - start - (if (candidates.isNotEmpty() || expanded) button else 0f)

    override fun origin() = start

    override fun clipScrolling(canvas: Canvas) {
        canvas.clipRect(start, 0f, start + viewport(), height.toFloat())
    }

    override fun onTap(item: Item) {
        when (val tag = item.tag) {
            is Int -> listener.onCandidate(tag)
            Kind.MENU -> listener.onMenu()
            Kind.CHIP -> listener.onChip()
            Kind.BADGE -> listener.onIncognito()
            Kind.EXPAND -> listener.onExpand()
            Kind.NOTICE -> listener.onNotice()
        }
    }

    override fun drawItem(canvas: Canvas, item: Item) {
        val r = item.rect
        val cy = r.centerY()
        when (val tag = item.tag) {
            is Int -> {
                if (tag == 0) PixelFrame.CHIP.draw(canvas, r.left + 2 * density, r.top + 7 * density, r.right - 2 * density, r.bottom - 7 * density, px)
                canvas.drawText(item.label, r.left + 12 * density, cy + text.textSize * 0.35f, text)
            }
            Kind.NOTICE -> canvas.drawText(item.label, r.left + 8 * density, cy + small.textSize * 0.35f, small)
            Kind.MENU -> Icons.draw(canvas, if (menuOpen) Icon.MENU_OPEN else Icon.MENU, r.centerX(), cy, 22 * density, Picnic.INK)
            Kind.EXPAND -> Icons.draw(canvas, if (expanded) Icon.COLLAPSE else Icon.EXPAND, r.centerX(), cy, 22 * density, Picnic.INK)
            Kind.BADGE -> Icons.draw(canvas, Icon.INCOGNITO, r.centerX(), cy, 22 * density,
                if (badge == Badge.TOGGLE) Picnic.BERRY else Picnic.MUTED)
            Kind.CHIP -> {
                val s = 32 * density
                chipFrame.draw(canvas, r.centerX() - s / 2, cy - s / 2, r.centerX() + s / 2, cy + s / 2, px)
                text.textSize = 17 * density
                val w = text.measureText(item.label)
                canvas.drawText(item.label, r.centerX() - w / 2 - px / 2, cy + text.textSize * 0.35f - px / 2, text)
                text.textSize = 18 * density
            }
        }
    }
}
