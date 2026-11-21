package dev.sebb.sebtype

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import dev.sebb.sebtype.Icons.Icon

/** What the action bar and All Actions offer (#53 B1–B4), in All Actions' order */
enum class Action(val label: Int, val icon: Icon) {
    EMOJI(R.string.action_emoji, Icon.EMOJI),
    SETTINGS(R.string.action_settings, Icon.SETTINGS),
    UNDO(R.string.action_undo, Icon.UNDO),
    REDO(R.string.action_redo, Icon.REDO),
    CLIPBOARD(R.string.action_clipboard, Icon.CLIPBOARD),
    INCOGNITO(R.string.incognito, Icon.INCOGNITO),
    MODES(R.string.action_modes, Icon.MODES),
    LANGUAGE(R.string.action_language, Icon.GLOBE),
    PASTE(R.string.action_paste, Icon.PASTE),
    CUT(R.string.action_cut, Icon.CUT),
    COPY(R.string.action_copy, Icon.COPY),
    SELECT_ALL(R.string.action_select_all, Icon.SELECT_ALL);

    companion object {
        /** The action bar's shortcuts as a fresh install has them: today's */
        private val DEFAULT = listOf(EMOJI, UNDO, REDO, CLIPBOARD, INCOGNITO, MODES)
        /** As many as the bar has room for next to ⋯ */
        const val MAX_PINNED = 6

        fun pinned(context: Context): List<Action> =
            prefs(context).getString("actions", null)?.split(',')?.mapNotNull { n -> entries.firstOrNull { it.name == n } } ?: DEFAULT

        fun setPinned(context: Context, actions: List<Action>) =
            prefs(context).edit().putString("actions", actions.joinToString(",") { it.name }).apply()

        private fun prefs(context: Context) = context.getSharedPreferences("keyboard", Context.MODE_PRIVATE)
    }
}

/**
 * The action bar, a row over the candidate bar (whose button opens and closes it): ⋯ (All Actions), 中文's
 * 简/繁 toggle in Chinese mode (#430), then the shortcuts up to 56 dp apart.
 */
@SuppressLint("ViewConstructor")
class ActionRow(context: Context, private val texts: Texts, private val listener: Listener) : ItemsView(context, vertical = false) {
    interface Listener {
        fun onAllActions()
        fun onAction(action: Action)
        fun onTraditional(on: Boolean)
    }

    internal object All
    internal object Traditional

    companion object {
        const val HEIGHT_DP = 40

        internal fun layout(width: Float, density: Float, actions: List<Action>, traditional: Boolean?): List<Triple<Float, Float, Any>> {
            val first = 45 * density
            val rest = actions.size + if (traditional != null) 1 else 0
            val step = minOf(56 * density, (width - first) / maxOf(Action.MAX_PINNED, rest))
            val out = ArrayList<Triple<Float, Float, Any>>(1 + rest)
            out += Triple(0f, first, All)
            var i = 0
            if (traditional != null) {
                val l = first + i++ * step
                out += Triple(l, l + step, Traditional)
            }
            actions.forEach { a ->
                val l = first + i++ * step
                out += Triple(l, l + step, a)
            }
            return out
        }

        internal fun iconSize(slotWidth: Float, density: Float) =
            minOf(22 * density, maxOf(8 * density, slotWidth - 2 * density))

        internal fun glyphSize(slotWidth: Float, density: Float) =
            minOf(18 * density, maxOf(8 * density, slotWidth - 2 * density))
    }

    private val density = resources.displayMetrics.density
    private val glyph = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 18 * density
        textAlign = Paint.Align.CENTER
        typeface = Typeface.DEFAULT_BOLD
    }
    private var actions = emptyList<Action>()
    private var on = emptySet<Action>()
    private var traditional: Boolean? = null

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) =
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), (HEIGHT_DP * density).toInt())

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) = rebuild()

    /** [on]: actions drawn as turned on (incognito); [traditional]: null outside 中文 */
    fun show(actions: List<Action>, on: Set<Action>, traditional: Boolean?) {
        if (actions == this.actions && on == this.on && traditional == this.traditional) return
        this.actions = actions
        this.on = on
        this.traditional = traditional
        rebuild()
    }

    private fun rebuild() {
        if (width == 0) return
        val h = height.toFloat()
        val out = layout(width.toFloat(), density, actions, traditional).map { (l, r, tag) ->
            when (tag) {
                All -> Item(RectF(l, 0f, r, h), texts[R.string.menu_title], "android.widget.Button", fixed = true, tag = All)
                Traditional -> Item(RectF(l, 0f, r, h), if (traditional == true) "繁體" else "简体", "android.widget.Button",
                    fixed = true, checked = traditional, tag = Traditional)
                else -> {
                    val a = tag as Action
                    Item(RectF(l, 0f, r, h), texts[a.label], "android.widget.Button",
                        fixed = true, checked = if (a == Action.INCOGNITO) a in on else null, tag = a)
                }
            }
        }
        setItems(out, 0f)
    }

    override fun onTap(item: Item) {
        when (val tag = item.tag) {
            All -> listener.onAllActions()
            Traditional -> listener.onTraditional(traditional != true)
            is Action -> listener.onAction(tag)
        }
    }

    override fun drawItem(canvas: Canvas, item: Item) {
        val r = item.rect
        val icon = iconSize(r.width(), density)
        when (val tag = item.tag) {
            All -> Icons.draw(canvas, Icon.MORE, r.centerX(), r.centerY(), icon, Picnic.INK)
            Traditional -> {
                val on = traditional == true
                glyph.textSize = glyphSize(r.width(), density)
                glyph.color = if (on) Picnic.BERRY else Picnic.INK
                canvas.drawText(if (on) "繁" else "简", r.centerX(), r.centerY() - (glyph.ascent() + glyph.descent()) / 2f, glyph)
            }
            is Action -> Icons.draw(canvas, tag.icon, r.centerX(), r.centerY(), icon, if (tag in on) Picnic.BERRY else Picnic.INK)
        }
    }
}

/**
 * All Actions, in place of the keys (the bar shows ← and its title): 中文's 简/繁 switch (#36), then every
 * action as a rounded cream tile, three to a row, as today's action panel. Editing, the tiles show which
 * are the bar's shortcuts (numbered, in the bar's order) and a tap adds or removes one.
 */
@SuppressLint("ViewConstructor")
class ActionsPanel(context: Context, private val texts: Texts, private val listener: Listener) : ItemsView(context, vertical = true) {
    interface Listener {
        fun onTraditional(on: Boolean)
        fun onAction(action: Action)
        fun onPinned(actions: List<Action>)
    }

    private val density = resources.displayMetrics.density
    private val bold = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 17 * density
        color = Picnic.INK
        typeface = Typeface.DEFAULT_BOLD
    }
    private val regular = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 15 * density
        color = Picnic.INK
        textAlign = Paint.Align.CENTER
    }
    private val number = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 13 * density
        color = Picnic.WHITE
        textAlign = Paint.Align.CENTER
        typeface = Typeface.DEFAULT_BOLD
    }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE; strokeWidth = 2 * density }
    private var traditional: Boolean? = null
    private var on = emptySet<Action>()
    private var pinned = emptyList<Action>()
    var editing = false
        private set

    private enum class Kind { SIMPLIFIED, TRADITIONAL }

    /** [traditional]: null outside 中文, where the switch isn't shown */
    fun show(traditional: Boolean?, on: Set<Action>, pinned: List<Action>, editing: Boolean) {
        this.traditional = traditional
        this.on = on
        this.pinned = pinned
        val keep = editing == this.editing
        this.editing = editing
        rebuild(keep)
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) = rebuild(true)

    private fun rebuild(keepScroll: Boolean) {
        if (width == 0) return
        val pad = 10 * density
        val gap = 16 * density
        val out = ArrayList<Item>()
        var y = 8 * density
        traditional?.takeIf { !editing }?.let { on ->
            val h = 56 * density
            val mid = width / 2f
            out += Item(RectF(pad, y, mid - 28 * density, y + h), "简体", "android.widget.TextView", tag = Kind.SIMPLIFIED)
            out += Item(RectF(mid - 28 * density, y, width - pad, y + h), "繁體", "android.widget.Switch", checked = on, tag = Kind.TRADITIONAL)
            y += h + gap
        }
        val tile = (width - 2 * pad - 2 * gap) / 3
        val tileH = 92 * density
        Action.entries.forEachIndexed { i, a ->
            val l = pad + (i % 3) * (tile + gap)
            val t = y + (i / 3) * (tileH + gap)
            val checked = when {
                editing -> a in pinned
                a == Action.INCOGNITO -> a in on
                else -> null
            }
            out += Item(RectF(l, t, l + tile, t + tileH), texts[a.label],
                if (checked != null) "android.widget.CheckBox" else "android.widget.Button", checked = checked, tag = a)
        }
        y += ((Action.entries.size + 2) / 3) * (tileH + gap)
        setItems(out, y, keepScroll)
    }

    override fun onTap(item: Item) {
        when (val tag = item.tag) {
            Kind.SIMPLIFIED -> listener.onTraditional(false)
            Kind.TRADITIONAL -> listener.onTraditional(traditional != true)
            is Action -> if (!editing) listener.onAction(tag) else listener.onPinned(when {
                tag in pinned -> pinned - tag
                pinned.size < Action.MAX_PINNED -> pinned + tag
                else -> return
            })
        }
    }

    private fun card(canvas: Canvas, l: Float, t: Float, r: Float, b: Float, color: Int = Picnic.CREAM) =
        canvas.drawRoundRect(l, t, r, b, 15 * density, 15 * density, fill.apply { this.color = color })

    override fun drawItem(canvas: Canvas, item: Item) {
        val r = item.rect
        val cy = r.centerY()
        when (val tag = item.tag) {
            // One card for 简体 [switch] 繁體, centred: drawn with its left part.
            Kind.SIMPLIFIED -> {
                card(canvas, r.left, r.top, width - r.left, r.bottom)
                bold.typeface = if (traditional == true) Typeface.DEFAULT else Typeface.DEFAULT_BOLD
                canvas.drawText(item.label, width / 2f - 40 * density - bold.measureText(item.label), cy + bold.textSize * 0.35f, bold)
            }
            Kind.TRADITIONAL -> {
                bold.typeface = if (item.checked == true) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
                canvas.drawText(item.label, width / 2f + 40 * density, cy + bold.textSize * 0.35f, bold)
                drawSwitch(canvas, width / 2f, cy, item.checked == true)
            }
            is Action -> {
                val lit = !editing && tag in on
                card(canvas, r.left, r.top, r.right, r.bottom, if (lit) Picnic.PINK else Picnic.CREAM)
                if (editing && tag in pinned) {
                    stroke.color = Picnic.BERRY
                    canvas.drawRoundRect(r.left + density, r.top + density, r.right - density, r.bottom - density, 15 * density, 15 * density, stroke)
                    val bx = r.right - 14 * density
                    val by = r.top + 14 * density
                    canvas.drawCircle(bx, by, 9 * density, fill.apply { color = Picnic.BERRY })
                    canvas.drawText("${pinned.indexOf(tag) + 1}", bx, by + number.textSize * 0.35f, number)
                }
                Icons.draw(canvas, tag.icon, r.centerX(), r.top + 34 * density, 24 * density, Picnic.INK)
                val lines = wrap(item.label, r.width() - 12 * density)
                val step = regular.textSize * 1.15f
                lines.forEachIndexed { i, line ->
                    canvas.drawText(line, r.centerX(), r.top + 70 * density + step * (i - (lines.size - 1) / 2f), regular)
                }
            }
        }
    }

    /** [label] in at most two lines of [room] px, broken between words ("Clipboard / Manager", as today's), else anywhere (中文, 日本語) */
    private fun wrap(label: String, room: Float): List<String> {
        if (regular.measureText(label) <= room) return listOf(label)
        val words = label.split(' ')
        for (n in words.size - 1 downTo 1) {
            val first = words.take(n).joinToString(" ")
            if (regular.measureText(first) <= room) return listOf(first, words.drop(n).joinToString(" "))
        }
        val n = regular.breakText(label, true, room, null).coerceAtLeast(1)
        return listOf(label.take(n), label.drop(n))
    }

    /** A round switch centred at ([cx], [cy]): a tan track with a brown knob left (off), brown with a cream knob right (on) */
    private fun drawSwitch(canvas: Canvas, cx: Float, cy: Float, on: Boolean) {
        val w = 52 * density
        val h = 32 * density
        val l = cx - w / 2
        fill.color = if (on) Picnic.OUTLINE else Picnic.LINE
        canvas.drawRoundRect(l, cy - h / 2, l + w, cy + h / 2, h / 2, h / 2, fill)
        stroke.color = Picnic.OUTLINE
        canvas.drawRoundRect(l + density, cy - h / 2 + density, l + w - density, cy + h / 2 - density, h / 2, h / 2, stroke)
        fill.color = if (on) Picnic.CREAM else Picnic.OUTLINE
        canvas.drawCircle(if (on) l + w - h / 2 else l + h / 2, cy, if (on) 12 * density else 8 * density, fill)
    }
}
