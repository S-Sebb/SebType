package dev.sebb.sebtype.next

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import dev.sebb.sebtype.next.Icons.Icon

/**
 * The bar over the keys, as today's keyboard draws it. From the left: 日本語's あ|ア chip (#38), the menu
 * button (› in a cream circle, while there are no candidates), the incognito badge (#31), then the
 * candidates in cells at least 58 dp wide with lines between them, scrolling sideways, the first on a pink
 * chip (#28); the chevron at the right end opens all of them. While 中文 sets itself up, or after its setup
 * failed, a notice takes the candidates' place.
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
    private val barHeight = (40 * density).toInt()
    private val button = 45 * density
    private val chipWidth = 78.5f * density
    private val cellWidth = 58 * density
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
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val title = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 17 * density; color = Picnic.INK }
    private val kana = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 17 * density; textAlign = Paint.Align.CENTER }

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
        chip?.let {
            out += Item(RectF(x, 0f, x + chipWidth, h), it, Role.BUTTON, fixed = true, tag = Kind.CHIP)
            x += chipWidth
        }
        if (candidates.isEmpty() || menuOpen) {
            out += Item(RectF(x, 0f, x + button, h), context.getString(if (menuOpen) R.string.close_menu else R.string.open_menu),
                Role.BUTTON, fixed = true, tag = Kind.MENU)
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
            var cx = start
            candidates.forEachIndexed { i, c ->
                val w = maxOf(cellWidth, text.measureText(c) + 16 * density)
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

    /** How many candidates start inside the bar: the expanded view goes on after them */
    fun shownCount() = items.count { it.tag is Int && it.rect.left < viewport() }

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
                if (tag == 0) PixelFrame.CHIP.draw(canvas, r.left + 5 * density, r.top + 7 * density, r.right - 5 * density, r.bottom - 7 * density, px)
                // A thin line between candidates
                else fill.apply { color = Picnic.OUTLINE }.let { canvas.drawRect(r.left, cy - 12.5f * density, r.left + density, cy + 12.5f * density, it) }
                canvas.drawText(item.label, r.centerX() - text.measureText(item.label) / 2, cy + text.textSize * 0.35f, text)
            }
            Kind.NOTICE -> canvas.drawText(item.label, r.left + 8 * density, cy + small.textSize * 0.35f, small)
            // Open: ← and the menu's title, as today's action panel
            Kind.MENU -> if (menuOpen) {
                Icons.draw(canvas, Icon.PREVIOUS, r.centerX(), cy, 22 * density, Picnic.INK)
                title.let { canvas.drawText(context.getString(R.string.menu_title), r.right + 6 * density, cy + it.textSize * 0.35f, it) }
            } else {
                canvas.drawCircle(r.right - 22.5f * density, cy, 16 * density, fill.apply { color = Picnic.CREAM })
                Icons.draw(canvas, if (menuOpen) Icon.MENU_OPEN else Icon.MENU, r.right - 22.5f * density, cy, 16 * density, Picnic.INK)
            }
            // ^ opens all the candidates, v closes them again
            Kind.EXPAND -> Icons.draw(canvas, if (expanded) Icon.EXPAND else Icon.COLLAPSE, r.centerX(), cy, 18 * density, Picnic.INK)
            Kind.BADGE -> Icons.draw(canvas, Icon.INCOGNITO, r.centerX(), cy, 22 * density,
                if (badge == Badge.TOGGLE) Picnic.BERRY else Picnic.MUTED)
            // A pill: あ and ア side by side, the one in use on berry
            Kind.CHIP -> {
                val l = r.left + 8 * density
                val w = 70.5f * density
                val half = 13 * density
                val hiragana = item.label == "あ"
                fill.color = Picnic.CREAM
                canvas.drawRoundRect(l, cy - half, l + w, cy + half, half, half, fill)
                fill.color = Picnic.BERRY
                canvas.save()
                canvas.clipRect(if (hiragana) l else l + w / 2, cy - half, if (hiragana) l + w / 2 else l + w, cy + half)
                canvas.drawRoundRect(l, cy - half, l + w, cy + half, half, half, fill)
                canvas.restore()
                for ((i, k) in listOf("あ", "ア").withIndex()) {
                    kana.color = if (hiragana == (i == 0)) Picnic.WHITE else Picnic.FADED
                    canvas.drawText(k, l + w / 4 * (1 + 2 * i), cy + kana.textSize * 0.35f, kana)
                }
            }
        }
    }
}
