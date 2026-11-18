package dev.sebb.sebtype

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface

/**
 * The emoji picker's list (#53 B1): Unicode's emoji in Unicode's order and groups, with their CLDR names and
 * keywords in the three languages (assets/emoji/emoji.txt, built by data/emoji/build.sh), less those the
 * system's emoji font can't draw, then today's ASCII faces. The recently used ones and each emoji's last skin
 * tone are kept in the keyboard's preferences.
 */
object Emoji {
    class Item(val text: String, private val names: Array<String>, val tones: List<String>, keywords: List<String>, val face: Boolean) {
        /** Its name in [Texts.language]'s order: English, 中文, 日本語 */
        fun name(language: Int) = names.getOrElse(language) { names[0] }

        /** What a search finds it by: its names and keywords in all three languages, in lower case */
        val keys = (names.asList() + keywords).map { it.lowercase() }.distinct()
    }

    class Group(val name: String, val items: List<Item>)

    @Volatile private var groups: List<Group>? = null
    @Volatile private var byName: Map<String, String>? = null

    /** Read once per process, the first time the picker opens (or English suggests one) */
    fun groups(context: Context): List<Group> = groups ?: load(context).also { groups = it }

    /** The emoji an English [word] names: its CLDR name is the word, or the word and "face" ("cat" 🐈, "pig" 🐖) */
    fun forWord(context: Context, word: String): String? {
        val names = byName ?: groups(context).flatMap { it.items }.asReversed().associate { it.name(0).lowercase() to it.text }
            .also { byName = it }
        val w = word.lowercase()
        return names[w] ?: names["$w face"]
    }

    /**
     * Today's search: the emoji a name or keyword equals [query], then those one starts with it, then those
     * one contains it; at most 30.
     */
    fun search(context: Context, query: String) = search(groups(context).flatMap { it.items }, query)

    fun search(items: List<Item>, query: String): List<Item> {
        val q = query.trim().lowercase()
        return items.asSequence().mapNotNull { item ->
            when {
                item.keys.any { it == q } -> 0
                item.keys.any { it.startsWith(q) } -> 1
                item.keys.any { it.contains(q) } -> 2
                else -> null
            }?.let { item to it }
        }.sortedBy { it.second }.take(30).map { it.first }.toList()
    }

    /** The last group: ASCII faces, typed with a space either side, wider than an emoji */
    const val FACES = "ASCII"

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
                val face = name == FACES
                if (f.size < 4 || !face && !paint.hasGlyph(f[0])) continue
                items += Item(f[0], arrayOf(f[1], f[2], f[3]), f.getOrNull(4)?.split(' ')?.filter { it.isNotEmpty() }.orEmpty(),
                    f.drop(5).flatMap { it.split('|') }.filter { it.isNotEmpty() }, face)
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
 * The emoji picker, in place of the keys: the emoji in rows of nine under their groups' names, scrolling
 * down, the recently used first, the ASCII faces last and wider; along the bottom ABC (back to the keys), a
 * tab per group, and Delete. A long press on one with skin tones shows them over it. Each is labelled with its
 * CLDR name in the keyboard's language, which TalkBack reads. As [results] it shows a search's finds alone,
 * over the keys that type the search.
 */
@SuppressLint("ViewConstructor")
class EmojiPanel(context: Context, private val texts: Texts, private val listener: Listener, private val results: Boolean = false) :
    ItemsView(context, vertical = true) {
    interface Listener {
        fun onEmoji(text: String, face: Boolean)
        fun onLetters()
        fun onDelete()
    }

    /** What the search is for: its results show */
    var query = ""
        set(value) {
            field = value
            tones = null
            rebuild(false)
        }

    private val density = resources.displayMetrics.density
    private val glyph = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 28 * density; textAlign = Paint.Align.CENTER }
    private val tab = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 20 * density; textAlign = Paint.Align.CENTER }
    private val heading = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 13 * density; color = Picnic.MUTED }
    private val abc = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 15 * density; color = Picnic.INK; textAlign = Paint.Align.CENTER; typeface = Typeface.DEFAULT_BOLD
    }
    private val face = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER; color = Picnic.INK }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val tabsHeight = if (results) 0f else 44 * density
    // Nine to a row on a phone, as today's
    private val cell = 45 * density
    private val headingHeight = 28 * density

    private class Emo(val item: Emoji.Item, val shown: String)
    private class Tab(val group: Int)
    private class Heading(val title: String)
    private class Tone(val text: String, val base: Emoji.Item)
    private enum class Kind { LETTERS, DELETE }

    private companion object {
        /** The ASCII faces' tab */
        const val FACES_TAB = ":)"
    }

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
        if (!results) {
            fill.color = Picnic.CREAM
            canvas.drawRect(0f, viewport(), width.toFloat(), height.toFloat(), fill)
        }
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
        if (results) return showResults()
        val all = Emoji.groups(context)
        val byText = all.flatMap { it.items }.associateBy { it.text }
        // The recent ones may be a tone of an emoji: found by the emoji it is a tone of.
        val toneOf = all.flatMap { g -> g.items.flatMap { i -> i.tones.map { it to i } } }.toMap()
        val recent = Emoji.recent(context).mapNotNull { r -> (byText[r] ?: toneOf[r])?.let { Emo(it, r) } }
        val sections = buildList {
            if (recent.isNotEmpty()) add(Triple(-1, texts[R.string.emoji_recent], recent))
            all.forEachIndexed { i, g -> add(Triple(i, groupName(g.name), g.items.map { Emo(it, Emoji.tone(context, it.text)) })) }
        }
        val out = ArrayList<Item>()
        val starts = ArrayList<Float>()
        var y = 0f
        for ((_, title, items) in sections) {
            starts += y
            out += Item(RectF(0f, y, width.toFloat(), y + headingHeight), title, "android.widget.TextView", tag = Heading(title))
            y = place(items, y + headingHeight, out)
        }
        this.starts = starts.toFloatArray()
        groups = sections.map { (g, _, items) -> g to (if (g < 0) "" else if (items.first().item.face) FACES_TAB else items.first().item.text) }
        // The bottom row: ABC, the tabs, Delete
        val b = height.toFloat()
        val side = 56 * density
        out += Item(RectF(0f, b - tabsHeight, side, b), context.getString(R.string.key_letters), "android.widget.Button", fixed = true, tag = Kind.LETTERS)
        out += Item(RectF(width - side, b - tabsHeight, width.toFloat(), b), context.getString(R.string.key_delete), "android.widget.Button", fixed = true, tag = Kind.DELETE)
        val tw = (width - 2 * side) / groups.size
        groups.forEachIndexed { i, (_, _) ->
            out += Item(RectF(side + i * tw, b - tabsHeight, side + (i + 1) * tw, b), sections[i].second, "android.widget.Button", fixed = true, tag = Tab(i))
        }
        tones?.let { addTones(it, out) }
        setItems(out, y, keepScroll)
    }

    /** The skin tones of the emoji long-pressed at [at], over it */
    private fun addTones(at: Pair<RectF, Emoji.Item>, out: MutableList<Item>) {
        val (r, base) = at
        val variants = listOf(base.text) + base.tones
        val tw2 = minOf(cell, width.toFloat() / variants.size)
        val left = (r.centerX() - tw2 * variants.size / 2).coerceIn(0f, width - tw2 * variants.size)
        val top = (r.top - cell).coerceAtLeast(0f)
        variants.forEachIndexed { i, v ->
            out += Item(RectF(left + i * tw2, top, left + (i + 1) * tw2, top + cell), v, "android.widget.Button", fixed = true, tag = Tone(v, base))
        }
    }

    /** A search's finds, from the top: "No results found" for none */
    private fun showResults() {
        val out = ArrayList<Item>()
        val found = Emoji.search(context, query).map { Emo(it, if (it.tones.isEmpty()) it.text else Emoji.tone(context, it.text)) }
        val y = if (found.isEmpty()) {
            val none = texts[R.string.emoji_no_results]
            out += Item(RectF(0f, 0f, width.toFloat(), headingHeight), none, "android.widget.TextView", tag = Heading(none))
            headingHeight
        } else place(found, 0f, out)
        tones?.let { addTones(it, out) }
        setItems(out, y)
    }

    /**
     * Lays [items] out in rows from [top], into [out]; returns where they end. Emoji are a [cell] square each,
     * as many as fit; ASCII faces take a wider cell, as today's (a row of nine emoji holds five faces).
     */
    private fun place(items: List<Emo>, top: Float, out: MutableList<Item>): Float {
        val columns = maxOf(1, (width / cell).toInt())
        val faceColumns = maxOf(2, columns / 2 + 1)
        var x = 0f
        var y = top
        for (e in items) {
            val w = width.toFloat() / (if (e.item.face) faceColumns else columns)
            if (x + w > width + 0.5f) { x = 0f; y += cell }
            out += Item(RectF(x, y, x + w, y + cell), e.item.name(texts.language), "android.widget.Button", tag = e)
            x += w
        }
        return if (items.isEmpty()) y else y + cell
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
        Emoji.FACES -> texts[R.string.emoji_faces]
        else -> name
    }

    override fun onTap(item: Item) {
        val showingTones = tones != null
        if (showingTones) {
            tones = null
            rebuild(true)
        }
        when (val tag = item.tag) {
            is Tone -> pick(tag.text, tag.base)
            is Emo -> if (!showingTones) pick(tag.shown, tag.item)
            is Tab -> scrollTo(starts[tag.group])
            Kind.LETTERS -> listener.onLetters()
            Kind.DELETE -> listener.onDelete()
        }
    }

    private fun pick(text: String, base: Emoji.Item) {
        Emoji.used(context, text, base.text)
        listener.onEmoji(text, base.face)
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
            is Emo -> if (tag.item.face) {
                // A face as wide as its cell allows
                face.textSize = minOf(18 * density, 18 * density * (r.width() - 8 * density) / maxOf(1f, face.apply { textSize = 18 * density }.measureText(tag.shown)))
                canvas.drawText(tag.shown, r.centerX(), r.centerY() + face.textSize * 0.35f, face)
            } else canvas.drawText(tag.shown, r.centerX(), r.centerY() + glyph.textSize * 0.35f, glyph)
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
                else if (first == FACES_TAB) canvas.drawText(first, r.centerX(), r.centerY() + abc.textSize * 0.35f, abc)
                else canvas.drawText(first, r.centerX(), r.centerY() + tab.textSize * 0.35f, tab)
            }
            Kind.LETTERS -> canvas.drawText("ABC", r.centerX(), r.centerY() + abc.textSize * 0.35f, abc)
            Kind.DELETE -> Icons.draw(canvas, Icons.Icon.DELETE, r.centerX(), r.centerY(), 22 * density, Picnic.INK)
        }
    }
}
