package dev.sebb.sebtype.next

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface

/**
 * The emoji picker's list (#53 B1): Unicode's emoji in Unicode's order and groups, with their CLDR names in
 * the three languages (assets/emoji/emoji.txt, built by data/emoji/build.sh), less those the system's emoji
 * font can't draw. The recently used ones and each emoji's last skin tone are kept in the keyboard's
 * preferences.
 */
object Emoji {
    class Item(val text: String, private val names: Array<String>, val tones: List<String>) {
        /** Its name in [Texts.language]'s order: English, 中文, 日本語 */
        fun name(language: Int) = names.getOrElse(language) { names[0] }
    }

    class Group(val name: String, val items: List<Item>)

    private var groups: List<Group>? = null

    /** Read once per process, the first time the picker opens */
    fun groups(context: Context): List<Group> = groups ?: load(context).also { groups = it }

    private fun load(context: Context): List<Group> {
        val paint = Paint()
        val out = ArrayList<Group>()
        var items = ArrayList<Item>()
        var name = ""
        context.assets.open("emoji/emoji.txt").bufferedReader().useLines { lines ->
            for (line in lines) {
                if (line.startsWith("# ")) {
                    if (items.isNotEmpty()) out += Group(name, items)
                    name = line.substring(2)
                    items = ArrayList()
                    continue
                }
                val f = line.split('\t')
                if (f.size < 4 || !paint.hasGlyph(f[0])) continue
                items += Item(f[0], arrayOf(f[1], f[2], f[3]), f.getOrNull(4)?.split(' ').orEmpty())
            }
        }
        if (items.isNotEmpty()) out += Group(name, items)
        return out
    }

    private const val RECENT_MAX = 32

    fun recent(context: Context): List<String> =
        prefs(context).getString("emoji_recent", "")!!.split('\n').filter { it.isNotEmpty() }

    /** [emoji] was typed: first among the recent ones; a skin tone variant is remembered for its emoji. */
    fun used(context: Context, emoji: String, base: String) {
        val p = prefs(context)
        val list = listOf(emoji) + recent(context).filter { it != emoji }
        p.edit().putString("emoji_recent", list.take(RECENT_MAX).joinToString("\n"))
            .apply { if (emoji != base) putString("emoji_tone_$base", emoji) else remove("emoji_tone_$base") }.apply()
    }

    /** The variant last picked for [base], or [base] */
    fun tone(context: Context, base: String): String = prefs(context).getString("emoji_tone_$base", base)!!

    private fun prefs(context: Context) = context.getSharedPreferences("keyboard", Context.MODE_PRIVATE)
}

/**
 * The emoji picker, in place of the keys: the emoji in rows of eight under their groups' names, scrolling
 * down, the recently used first; along the bottom ABC (back to the keys), a tab per group, and Delete. A long
 * press on one with skin tones shows them over it. Each is labelled with its CLDR name in the keyboard's
 * language, which TalkBack reads.
 */
@SuppressLint("ViewConstructor")
class EmojiPanel(context: Context, private val texts: Texts, private val listener: Listener) : ItemsView(context, vertical = true) {
    interface Listener {
        fun onEmoji(text: String)
        fun onLetters()
        fun onDelete()
    }

    private val density = resources.displayMetrics.density
    private val glyph = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 28 * density; textAlign = Paint.Align.CENTER }
    private val tab = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 20 * density; textAlign = Paint.Align.CENTER }
    private val heading = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 13 * density; color = Picnic.MUTED }
    private val abc = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 15 * density; color = Picnic.INK; textAlign = Paint.Align.CENTER; typeface = Typeface.DEFAULT_BOLD
    }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val tabsHeight = 44 * density
    // Nine to a row on a phone, as today's
    private val cell = 45 * density
    private val headingHeight = 28 * density

    private class Emo(val item: Emoji.Item, val shown: String)
    private class Tab(val group: Int)
    private class Heading(val title: String)
    private class Tone(val text: String, val base: Emoji.Item)
    private enum class Kind { LETTERS, DELETE }

    /** Where each group starts, for its tab */
    private var starts = FloatArray(0)
    /** Each tab's group: -1 for the recent ones */
    private var groups = emptyList<Pair<Int, String>>()
    private var tones: Pair<RectF, Emoji.Item>? = null

    override fun viewport() = height - tabsHeight

    override fun clipScrolling(canvas: Canvas) {
        canvas.clipRect(0f, 0f, width.toFloat(), viewport())
    }

    override fun onDraw(canvas: Canvas) {
        canvas.drawColor(Picnic.CLOTH)
        fill.color = Picnic.CREAM
        canvas.drawRect(0f, viewport(), width.toFloat(), height.toFloat(), fill)
        super.onDraw(canvas)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) = rebuild(false)

    /** Opened again: the recent ones as they are now, from the top */
    fun open() {
        tones = null
        rebuild(false)
    }

    private fun rebuild(keepScroll: Boolean) {
        if (width == 0) return
        val all = Emoji.groups(context)
        val byText = all.flatMap { it.items }.associateBy { it.text }
        // The recent ones may be a tone of an emoji: found by the emoji it is a tone of.
        val toneOf = all.flatMap { g -> g.items.flatMap { i -> i.tones.map { it to i } } }.toMap()
        val recent = Emoji.recent(context).mapNotNull { r -> (byText[r] ?: toneOf[r])?.let { Emo(it, r) } }
        val sections = buildList {
            if (recent.isNotEmpty()) add(Triple(-1, texts[R.string.emoji_recent], recent))
            all.forEachIndexed { i, g -> add(Triple(i, groupName(g.name), g.items.map { Emo(it, Emoji.tone(context, it.text)) })) }
        }
        val columns = maxOf(1, (width / cell).toInt())
        val w = width.toFloat() / columns
        val out = ArrayList<Item>()
        val starts = ArrayList<Float>()
        var y = 0f
        for ((_, title, items) in sections) {
            starts += y
            out += Item(RectF(0f, y, width.toFloat(), y + headingHeight), title, "android.widget.TextView", tag = Heading(title))
            y += headingHeight
            items.forEachIndexed { i, e ->
                val x = (i % columns) * w
                val top = y + (i / columns) * cell
                out += Item(RectF(x, top, x + w, top + cell), e.item.name(texts.language), "android.widget.Button", tag = e)
            }
            y += ((items.size + columns - 1) / columns) * cell
        }
        this.starts = starts.toFloatArray()
        groups = sections.map { (g, title, items) -> g to (if (g < 0) "" else items.first().item.text) }
        // The bottom row: ABC, the tabs, Delete
        val b = height.toFloat()
        val side = 56 * density
        out += Item(RectF(0f, b - tabsHeight, side, b), context.getString(R.string.key_letters), "android.widget.Button", fixed = true, tag = Kind.LETTERS)
        out += Item(RectF(width - side, b - tabsHeight, width.toFloat(), b), context.getString(R.string.key_delete), "android.widget.Button", fixed = true, tag = Kind.DELETE)
        val tw = (width - 2 * side) / groups.size
        groups.forEachIndexed { i, (_, _) ->
            out += Item(RectF(side + i * tw, b - tabsHeight, side + (i + 1) * tw, b), sections[i].second, "android.widget.Button", fixed = true, tag = Tab(i))
        }
        tones?.let { (r, base) ->
            val variants = listOf(base.text) + base.tones
            val tw2 = minOf(cell, width.toFloat() / variants.size)
            val left = (r.centerX() - tw2 * variants.size / 2).coerceIn(0f, width - tw2 * variants.size)
            val top = (r.top - cell).coerceAtLeast(0f)
            variants.forEachIndexed { i, v ->
                out += Item(RectF(left + i * tw2, top, left + (i + 1) * tw2, top + cell), v, "android.widget.Button", fixed = true, tag = Tone(v, base))
            }
        }
        setItems(out, y, keepScroll)
    }

    /** Unicode's group names (emoji-test.txt's) in the keyboard's language */
    private fun groupName(name: String) = when (name) {
        "Smileys & Emotion" -> texts[R.string.emoji_smileys]
        "People & Body" -> texts[R.string.emoji_people]
        "Animals & Nature" -> texts[R.string.emoji_animals]
        "Food & Drink" -> texts[R.string.emoji_food]
        "Travel & Places" -> texts[R.string.emoji_travel]
        "Activities" -> texts[R.string.emoji_activities]
        "Objects" -> texts[R.string.emoji_objects]
        "Symbols" -> texts[R.string.emoji_symbols]
        "Flags" -> texts[R.string.emoji_flags]
        else -> name
    }

    override fun onTap(item: Item) {
        val showingTones = tones != null
        if (showingTones) {
            tones = null
            rebuild(true)
        }
        when (val tag = item.tag) {
            is Tone -> pick(tag.text, tag.base.text)
            is Emo -> if (!showingTones) pick(tag.shown, tag.item.text)
            is Tab -> scrollTo(starts[tag.group])
            Kind.LETTERS -> listener.onLetters()
            Kind.DELETE -> listener.onDelete()
        }
    }

    private fun pick(text: String, base: String) {
        Emoji.used(context, text, base)
        listener.onEmoji(text)
    }

    override fun onLongPress(item: Item): Boolean {
        val e = item.tag as? Emo ?: return false
        if (e.item.tones.isEmpty()) return false
        tones = onScreen(item) to e.item
        rebuild(true)
        return true
    }

    override fun drawItem(canvas: Canvas, item: Item) {
        val r = item.rect
        when (val tag = item.tag) {
            is Heading -> canvas.drawText(tag.title, 12 * density, r.bottom - 8 * density, heading)
            is Emo -> canvas.drawText(tag.shown, r.centerX(), r.centerY() + glyph.textSize * 0.35f, glyph)
            is Tone -> {
                if (tag.text == tag.base.text) {
                    fill.color = Picnic.CREAM
                    val all = items.filter { it.tag is Tone }
                    val l = all.minOf { it.rect.left }
                    val rr = all.maxOf { it.rect.right }
                    canvas.drawRoundRect(l - 4 * density, r.top - 4 * density, rr + 4 * density, r.bottom + 4 * density, 12 * density, 12 * density, fill)
                    PixelFrame.CREAM.draw(canvas, l - 4 * density, r.top - 4 * density, rr + 4 * density, r.bottom + 4 * density, Picnic.pixel(context).toFloat())
                }
                canvas.drawText(tag.text, r.centerX(), r.centerY() + glyph.textSize * 0.35f, glyph)
            }
            is Tab -> {
                val (g, first) = groups[tag.group]
                if (g < 0) Icons.draw(canvas, Icons.Icon.RECENT, r.centerX(), r.centerY(), 20 * density, Picnic.INK)
                else canvas.drawText(first, r.centerX(), r.centerY() + tab.textSize * 0.35f, tab)
            }
            Kind.LETTERS -> canvas.drawText("ABC", r.centerX(), r.centerY() + abc.textSize * 0.35f, abc)
            Kind.DELETE -> Icons.draw(canvas, Icons.Icon.DELETE, r.centerX(), r.centerY(), 22 * density, Picnic.INK)
        }
    }
}
