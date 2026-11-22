package dev.sebb.sebtype

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import dev.sebb.sebtype.Icons.Icon

/**
 * The bar over the keys, as today's keyboard draws it. From the left: 日本語's あ|ア chip (#38), the action
 * bar's button (› in a cream circle, ^ while the action bar is open; hidden while 中文 or 日本語 is typed),
 * the incognito badge (#31), then the candidates. 中文 and 日本語 put them in cells at least 58 dp wide (日本語's
 * first 122 dp) with lines between them, scrolling sideways, the first on a pink chip (#28), and the chevron
 * at the right end opens all of them. English has three equal slots, the first candidate in the middle on
 * the chip; a word typed that a space would correct shows on the right, in quotes. While 中文 sets itself up, or after its setup
 * failed, a notice takes the candidates' place; with nothing typed, the text or image just copied is offered
 * (#53 B8). Over a panel (All Actions, emoji, …) it shows ← and the panel's title instead, and All Actions'
 * button, or the emoji and clipboard panels' search (#281).
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
        fun onSearch()
    }

    /**
     * Over a panel: its title, and the button at the right end (Edit actions), if any. [search] labels the
     * search at the right end: a pill with it written (emoji, as today's) or ([pill] false) a magnifier.
     */
    data class Header(val title: String, val button: String?, val search: String? = null, val pill: Boolean = false)

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
    /** An English slot's word, shrunk to fit (#454) */
    private val slotText = Paint(text)
    private val small = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        typeface = Picnic.fonts(context).first
        textSize = 14 * density
        color = Picnic.MUTED
    }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 1.5f * density }
    private val title = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 17 * density; color = Picnic.INK }
    /** The header's title and button, their text shrunk to fit a narrow keyboard (floating, resized, #283) */
    private val fitted = Paint(title)
    /** The header title's room, between ← and the header's button */
    private var titleRoom = 0f
    private val kana = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 17 * density; textAlign = Paint.Align.CENTER }

    private var candidates = emptyList<String>()
    private var chip: String? = null
    private var badge = Badge.NONE
    private var notice: String? = null
    private var header: Header? = null
    private var clip: Clipboard.Quick? = null
    private var typing = false
    private var style = Style.CELLS
    private var corrected = false
    private var barOpen = false
    var expanded = false
        private set
    /** Where the scrolling candidates start: after the fixed controls on the left */
    private var start = 0f
    /** Whether the expand/collapse button is shown at the right end of the bar (#429) */
    private var showExpand = false

    private object Role {
        const val CANDIDATE = "android.widget.TextView"
        const val BUTTON = "android.widget.Button"
    }

    private enum class Kind { MENU, CHIP, BADGE, NOTICE, EXPAND, CLIP, HEADER_BUTTON, SEARCH }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) =
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), barHeight)

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) = rebuild(false)

    /**
     * [typing]: a word or composition is being typed; otherwise the candidates are next words.
     * [corrected]: English's first candidate is what a space commits instead of the word typed, the second.
     */
    fun show(candidates: List<String>, typing: Boolean, style: Style, corrected: Boolean, barOpen: Boolean, chip: String?,
             badge: Badge, notice: String?, header: Header?, expanded: Boolean, clip: Clipboard.Quick?) {
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
            var end = width.toFloat()
            header.button?.let {
                val w = minOf(title.measureText(it) + 32 * density, width - button - 8 * density)
                out += Item(RectF(width - w - 8 * density, 0f, width.toFloat(), h), it, Role.BUTTON, fixed = true, tag = Kind.HEADER_BUTTON)
                end = width - w - 8 * density
            }
            header.search?.let {
                val w = if (header.pill) 128 * density else button
                out += Item(RectF(width - w - 4 * density, 0f, width - 4 * density, h), it, Role.BUTTON, fixed = true, tag = Kind.SEARCH)
                end = minOf(end, width - w - 4 * density)
            }
            titleRoom = end - button - 6 * density - 8 * density
            showExpand = false
            start = width.toFloat()
            setItems(out, 0f)
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
        var extent = 0f
        val notice = notice
        val clip = clip
        if (notice != null) {
            showExpand = false
            out += Item(RectF(x, 0f, width.toFloat(), h), notice, Role.CANDIDATE, tag = Kind.NOTICE)
        } else {
            // The copied text on a chip, up to a third of the bar, before any next words
            if (clip != null) {
                val w = (clip.text?.let { small.measureText(clipLabel(it)) } ?: (24 * density)) + 52 * density
                out += Item(RectF(x, 0f, x + w, h), texts[if (clip.text != null) R.string.quick_clip else R.string.quick_clip_image],
                    Role.BUTTON, fixed = true, tag = Kind.CLIP)
                x += w
                start = x
            }
            var cx = start
            if (slots) {
                // Left, middle, right: the candidates' indices in each
                val order = if (corrected) listOf(2, 0, 1) else listOf(1, 0, 2)
                val w = (width - start) / 3
                order.forEachIndexed { slot, i ->
                    val c = candidates.getOrNull(i) ?: return@forEachIndexed
                    val l = start + slot * w
                    out += Item(RectF(l, 0f, l + w, h), if (corrected && i == 1) "\"$c\"" else c, Role.CANDIDATE, tag = i)
                }
                cx = width.toFloat()
            } else candidates.forEachIndexed { i, c ->
                val min = if (i == 0 && style == Style.WIDE_FIRST) wideWidth else cellWidth
                val w = maxOf(min, text.measureText(c) + 16 * density)
                out += Item(RectF(cx, 0f, cx + w, h), c, Role.CANDIDATE, tag = i)
                cx += w
            }
            extent = cx - start
            showExpand = showExpandButton(slots, expanded, extent, width - start)
            if (showExpand)
                out += Item(RectF(width - button, 0f, width.toFloat(), h),
                    texts[if (expanded) R.string.fewer_candidates else R.string.more_candidates],
                    Role.BUTTON, fixed = true, tag = Kind.EXPAND)
        }
        // Scrolling items are placed from 0; the view draws them after the controls. While expanded the bar
        // stays at its start, so the expanded view goes on right after what it shows (#491).
        setItems(out.map { if (it.fixed) it else Item(RectF(it.rect).apply { offset(-start, 0f) }, it.label, it.role, tag = it.tag) },
            if (expanded) 0f else extent, keepScroll)
    }

    /** How many candidates the bar shows whole: the expanded view goes on after them */
    fun shownCount() = wholeCandidates(items.filter { it.tag is Int }.map { it.rect.right }, viewport())

    override fun viewport() = candidateViewport(width - start, showExpand, button)

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
            Kind.SEARCH -> listener.onSearch()
        }
    }

    override fun drawItem(canvas: Canvas, item: Item) {
        val r = item.rect
        val cy = r.centerY()
        when (val tag = item.tag) {
            is Int -> {
                // English's slots shrink a long word to fit, or cut it, and the chip hugs it inside the slot (#454)
                val slots = style == Style.SLOTS
                val (label, size) = if (slots) fitSlot(item.label, r.width() - 2 * SLOT_PAD_DP * density, text.textSize, MIN_SLOT_DP * density) {
                    text.measureText(it)
                } else item.label to text.textSize
                slotText.textSize = size
                val w = slotText.measureText(label)
                val half = if (slots) maxOf(24 * density, w / 2 + (SLOT_PAD_DP - 5) * density) else r.width() / 2 - 5 * density
                if (tag == 0) PixelFrame.CHIP.draw(canvas, r.centerX() - half, r.top + 7 * density, r.centerX() + half, r.bottom - 7 * density, px)
                // A thin line between candidates; English's slots have one before the middle and the right one.
                val line = if (style == Style.SLOTS) r.left > 0.5f else tag != 0
                if (line) fill.apply { color = Picnic.OUTLINE }.let { canvas.drawRect(r.left, cy - 12.5f * density, r.left + density, cy + 12.5f * density, it) }
                canvas.drawText(label, r.centerX() - w / 2, cy + size * 0.35f, slotText)
            }
            Kind.NOTICE -> canvas.drawText(item.label, r.left + 8 * density, cy + small.textSize * 0.35f, small)
            // Over a panel: ← and its title, as today's action panel
            Kind.MENU -> if (header != null) {
                Icons.draw(canvas, Icon.PREVIOUS, r.centerX(), cy, 22 * density, Picnic.INK)
                // Too small to read beside the button, the title goes: ← and the button say enough.
                val name = header?.title.orEmpty()
                if (fit(name, titleRoom) >= MIN_TITLE_DP * density) canvas.drawText(name, r.right + 6 * density, cy + fitted.textSize * 0.35f, fitted)
            } else {
                canvas.drawCircle(r.right - 22.5f * density, cy, 16 * density, fill.apply { color = Picnic.CREAM })
                Icons.draw(canvas, if (barOpen) Icon.COLLAPSE else Icon.MENU, r.right - 22.5f * density, cy, 16 * density, Picnic.INK)
            }
            // An outlined pill, as today's Edit actions
            Kind.HEADER_BUTTON -> {
                val half = 16 * density
                stroke.color = Picnic.OUTLINE
                canvas.drawRoundRect(r.left, cy - half, r.right - 8 * density, cy + half, half, half, stroke)
                fit(item.label, r.width() - 8 * density - 24 * density)
                canvas.drawText(item.label, (r.left + r.right - 8 * density) / 2 - fitted.measureText(item.label) / 2, cy + fitted.textSize * 0.35f, fitted)
            }
            Kind.CLIP -> {
                val half = 14 * density
                fill.color = Picnic.CREAM
                canvas.drawRoundRect(r.left + 6 * density, cy - half, r.right - 6 * density, cy + half, half, half, fill)
                Icons.draw(canvas, Icon.CLIPBOARD, r.left + 22 * density, cy, 16 * density, Picnic.INK)
                val text = clip?.text
                if (text != null) canvas.drawText(clipLabel(text), r.left + 36 * density, cy + small.textSize * 0.35f, small)
                else Icons.draw(canvas, Icon.IMAGE, r.left + 48 * density, cy, 18 * density, Picnic.INK)
            }
            // Today's search: a cream pill with the magnifier and "Search" (emoji), or the magnifier alone
            Kind.SEARCH -> if (header?.pill == true) {
                val half = 18 * density
                fill.color = Picnic.CREAM
                canvas.drawRoundRect(r.left, cy - half, r.right, cy + half, half, half, fill)
                Icons.draw(canvas, Icon.SEARCH, r.left + 20 * density, cy, 20 * density, Picnic.INK)
                canvas.drawText(item.label, r.left + 36 * density, cy + small.textSize * 0.35f, small)
            } else Icons.draw(canvas, Icon.SEARCH, r.centerX(), cy, 22 * density, Picnic.INK)
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

    /** [fitted] at the title's size, or smaller so [s] fits [room]; its text size */
    private fun fit(s: String, room: Float): Float {
        fitted.textSize = title.textSize
        val w = fitted.measureText(s)
        if (w > room) fitted.textSize *= maxOf(room, 0f) / w
        return fitted.textSize
    }
}

/** The header's title, shrunk to fit, is drawn while at least this big */
private const val MIN_TITLE_DP = 11f

/** An English slot's room on each side of its word: the chip's 5 dp inset and its padding around the word */
private const val SLOT_PAD_DP = 13f

/** An English candidate shrinks to fit its slot down to this size, then is cut */
private const val MIN_SLOT_DP = 11f

/**
 * [label] fitted to [room]: its text size, at most [size] and at least [min], and the label itself, cut in the
 * middle with … if it still doesn't fit, so words that differ at either end stay apart. [measure] is the width
 * of a string at [size].
 */
internal fun fitSlot(label: String, room: Float, size: Float, min: Float, measure: (String) -> Float): Pair<String, Float> {
    val w = measure(label)
    if (w <= room) return label to size
    val fit = maxOf(min, size * room / w)
    val scale = fit / size
    if (w * scale <= room) return label to fit
    var keep = label.length - 1
    while (keep > 1) {
        val head = (keep + 1) / 2
        val cut = label.take(head) + "…" + label.takeLast(keep - head)
        if (measure(cut) * scale <= room) return cut to fit
        keep--
    }
    return label.take(1) + "…" to fit
}

/** Whether the expand/collapse button is shown at the right end of the bar (#429). */
internal fun showExpandButton(slots: Boolean, expanded: Boolean, extent: Float, available: Float) =
    !slots && (expanded || (extent > 0f && extent > available))

/** The scrolling candidates' viewport width: full room after controls, minus the expand button when shown. */
internal fun candidateViewport(available: Float, showExpand: Boolean, button: Float) =
    available - (if (showExpand) button else 0f)

/** How many candidates, their right edges [rights] from the viewport's start, fit [viewport] whole (#491). */
internal fun wholeCandidates(rights: List<Float>, viewport: Float) = rights.count { it <= viewport }
