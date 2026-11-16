package dev.sebb.sebtype.next

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import dev.sebb.sebtype.next.Icons.Icon

/**
 * The bar over the keys, as today's keyboard draws it. From the left: 日本語's あ|ア chip (#38), the action
 * bar's button (› in a cream circle, ^ while the action bar is open; hidden while 中文 or 日本語 is typed),
 * the incognito badge (#31), then the candidates. 中文 and 日本語 put them in cells at least 58 dp wide (日本語's
 * first 122 dp) with lines between them, scrolling sideways, the first on a pink chip (#28), and the chevron
 * at the right end opens all of them. English has three equal slots, the first candidate in the middle on
 * the chip; a word typed that a space would correct shows on the right, in quotes. While 中文 sets itself up, or after its setup
 * failed, a notice takes the candidates' place; with nothing typed, the text just copied is offered (#53 B8).
 * Over a panel (All Actions, emoji, …) it shows ← and the panel's title instead, and All Actions' button.
 */
@SuppressLint("ViewConstructor")
class CandidateBar(context: Context, private val texts: Texts, private val listener: Listener) : ItemsView(context, vertical = false) {
    interface Listener {
        fun onCandidate(index: Int)
        fun onMenu()
        fun onChip()
        fun onIncognito()
        fun onExpand()
        fun onNotice()
        fun onClip()
        fun onHeaderButton()
    }

    /** Over a panel: its title, and the button at the right end (Edit actions), if any */
    data class Header(val title: String, val button: String?)

    enum class Badge { NONE, FIELD, TOGGLE }

    enum class Style { CELLS, WIDE_FIRST, SLOTS }

    private val density = resources.displayMetrics.density
    private val px = Picnic.pixel(context).toFloat()
    private val barHeight = (40 * density).toInt()
    private val button = 45 * density
    private val chipWidth = 78.5f * density
    private val cellWidth = 58 * density
    private val wideWidth = 122 * density
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
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 1.5f * density }
    private val title = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 17 * density; color = Picnic.INK }
    private val kana = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 17 * density; textAlign = Paint.Align.CENTER }

    private var candidates = emptyList<String>()
    private var chip: String? = null
    private var badge = Badge.NONE
    private var notice: String? = null
    private var header: Header? = null
    private var clip: String? = null
    private var typing = false
    private var style = Style.CELLS
    private var corrected = false
    private var barOpen = false
    var expanded = false
        private set
    /** Where the scrolling candidates start: after the fixed controls on the left */
    private var start = 0f

    private object Role {
        const val CANDIDATE = "android.widget.TextView"
        const val BUTTON = "android.widget.Button"
    }

    private enum class Kind { MENU, CHIP, BADGE, NOTICE, EXPAND, CLIP, HEADER_BUTTON }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) =
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), barHeight)

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) = rebuild(false)

    /**
     * [typing]: a word or composition is being typed; otherwise the candidates are next words.
     * [corrected]: English's first candidate is what a space commits instead of the word typed, the second.
     */
    fun show(candidates: List<String>, typing: Boolean, style: Style, corrected: Boolean, barOpen: Boolean, chip: String?,
             badge: Badge, notice: String?, header: Header?, expanded: Boolean, clip: String?) {
        val same = candidates == this.candidates
        if (same && typing == this.typing && style == this.style && corrected == this.corrected && barOpen == this.barOpen &&
            chip == this.chip && badge == this.badge && notice == this.notice && header == this.header &&
            expanded == this.expanded && clip == this.clip) return
        this.typing = typing
        this.style = style
        this.corrected = corrected
        this.barOpen = barOpen
        this.candidates = candidates
        this.chip = chip
        this.badge = badge
        this.notice = notice
        this.header = header
        this.expanded = expanded
        this.clip = clip
        rebuild(keepScroll = same)
    }

    private fun rebuild(keepScroll: Boolean) {
        if (width == 0) return
        val h = height.toFloat()
        val out = ArrayList<Item>()
        var x = 0f
        val header = header
        if (header != null) {
            out += Item(RectF(x, 0f, x + button, h), texts[R.string.back], Role.BUTTON, fixed = true, tag = Kind.MENU)
            header.button?.let {
                val w = title.measureText(it) + 32 * density
                out += Item(RectF(width - w - 8 * density, 0f, width.toFloat(), h), it, Role.BUTTON, fixed = true, tag = Kind.HEADER_BUTTON)
            }
            setItems(out, 0f)
            start = width.toFloat()
            return
        }
        chip?.let {
            out += Item(RectF(x, 0f, x + chipWidth, h), it, Role.BUTTON, fixed = true, tag = Kind.CHIP)
            x += chipWidth
        }
        if (!typing || style == Style.SLOTS) {
            out += Item(RectF(x, 0f, x + button, h), texts[if (barOpen) R.string.close_menu else R.string.open_menu],
                Role.BUTTON, fixed = true, tag = Kind.MENU)
            x += button
        }
        if (badge != Badge.NONE) {
            val label = texts[if (badge == Badge.TOGGLE) R.string.incognito_on else R.string.incognito_field]
            out += Item(RectF(x, 0f, x + button, h), label, Role.BUTTON, fixed = true, tag = Kind.BADGE)
            x += button
        }
        start = x
        val slots = style == Style.SLOTS
        val end = if (slots) width.toFloat() else width - button
        var extent = 0f
        val notice = notice
        val clip = clip
        if (notice != null) {
            out += Item(RectF(x, 0f, width.toFloat(), h), notice, Role.CANDIDATE, tag = Kind.NOTICE)
        } else {
            // The copied text on a chip, up to a third of the bar, before any next words
            if (clip != null) {
                val w = small.measureText(clipLabel(clip)) + 52 * density
                out += Item(RectF(x, 0f, x + w, h), texts[R.string.quick_clip], Role.BUTTON, fixed = true, tag = Kind.CLIP)
                x += w
                start = x
            }
            var cx = start
            if (slots) {
                // Left, middle, right: the candidates' indices in each
                val order = if (corrected) listOf(2, 0, 1) else listOf(1, 0, 2)
                val w = (end - start) / 3
                order.forEachIndexed { slot, i ->
                    val c = candidates.getOrNull(i) ?: return@forEachIndexed
                    val l = start + slot * w
                    out += Item(RectF(l, 0f, l + w, h), if (corrected && i == 1) "\"$c\"" else c, Role.CANDIDATE, tag = i)
                }
                cx = end
            } else candidates.forEachIndexed { i, c ->
                val min = if (i == 0 && style == Style.WIDE_FIRST) wideWidth else cellWidth
                val w = maxOf(min, text.measureText(c) + 16 * density)
                out += Item(RectF(cx, 0f, cx + w, h), c, Role.CANDIDATE, tag = i)
                cx += w
            }
            extent = cx - start
            if (!slots && (candidates.isNotEmpty() || expanded))
                out += Item(RectF(end, 0f, width.toFloat(), h),
                    texts[if (expanded) R.string.fewer_candidates else R.string.more_candidates],
                    Role.BUTTON, fixed = true, tag = Kind.EXPAND)
        }
        // Scrolling items are placed from 0; the view draws them after the controls.
        setItems(out.map { if (it.fixed) it else Item(RectF(it.rect).apply { offset(-start, 0f) }, it.label, it.role, tag = it.tag) },
            extent, keepScroll)
    }

    /** How many candidates start inside the bar: the expanded view goes on after them */
    fun shownCount() = items.count { it.tag is Int && it.rect.left < viewport() }

    override fun viewport() = width - start - (if (style != Style.SLOTS && (candidates.isNotEmpty() || expanded)) button else 0f)

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
            Kind.CLIP -> listener.onClip()
            Kind.HEADER_BUTTON -> listener.onHeaderButton()
        }
    }

    override fun drawItem(canvas: Canvas, item: Item) {
        val r = item.rect
        val cy = r.centerY()
        when (val tag = item.tag) {
            is Int -> {
                if (tag == 0) PixelFrame.CHIP.draw(canvas, r.left + 5 * density, r.top + 7 * density, r.right - 5 * density, r.bottom - 7 * density, px)
                // A thin line between candidates (English's slots have none)
                else if (style != Style.SLOTS) fill.apply { color = Picnic.OUTLINE }.let { canvas.drawRect(r.left, cy - 12.5f * density, r.left + density, cy + 12.5f * density, it) }
                canvas.drawText(item.label, r.centerX() - text.measureText(item.label) / 2, cy + text.textSize * 0.35f, text)
            }
            Kind.NOTICE -> canvas.drawText(item.label, r.left + 8 * density, cy + small.textSize * 0.35f, small)
            // Over a panel: ← and its title, as today's action panel
            Kind.MENU -> if (header != null) {
                Icons.draw(canvas, Icon.PREVIOUS, r.centerX(), cy, 22 * density, Picnic.INK)
                canvas.drawText(header?.title.orEmpty(), r.right + 6 * density, cy + title.textSize * 0.35f, title)
            } else {
                canvas.drawCircle(r.right - 22.5f * density, cy, 16 * density, fill.apply { color = Picnic.CREAM })
                Icons.draw(canvas, if (barOpen) Icon.COLLAPSE else Icon.MENU, r.right - 22.5f * density, cy, 16 * density, Picnic.INK)
            }
            // An outlined pill, as today's Edit actions
            Kind.HEADER_BUTTON -> {
                val half = 16 * density
                stroke.color = Picnic.OUTLINE
                canvas.drawRoundRect(r.left, cy - half, r.right - 8 * density, cy + half, half, half, stroke)
                canvas.drawText(item.label, (r.left + r.right - 8 * density) / 2 - title.measureText(item.label) / 2, cy + title.textSize * 0.35f, title)
            }
            Kind.CLIP -> {
                val half = 14 * density
                fill.color = Picnic.CREAM
                canvas.drawRoundRect(r.left + 6 * density, cy - half, r.right - 6 * density, cy + half, half, half, fill)
                Icons.draw(canvas, Icon.CLIPBOARD, r.left + 22 * density, cy, 16 * density, Picnic.INK)
                canvas.drawText(clipLabel(clip.orEmpty()), r.left + 36 * density, cy + small.textSize * 0.35f, small)
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

    /** The copied text on one line, cut to a third of the bar */
    private fun clipLabel(text: String): String {
        val line = text.trim().replace(Regex("\\s+"), " ")
        val n = small.breakText(line, true, width / 3f, null)
        return if (n < line.length) line.take(maxOf(1, n - 1)) + "…" else line
    }
}
