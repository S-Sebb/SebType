package dev.sebb.sebtype.next

import android.annotation.SuppressLint
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.os.Build
import android.text.StaticLayout
import android.text.TextPaint
import android.text.TextUtils
import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

/**
 * What was copied: the clipboard history (#26, #53 B8), kept only while the user keeps it on, and the quick
 * clip, the text just copied, offered in the bar for [QUICK_MS]. Nothing copied in a private or password field,
 * while incognito is on (#31, #139) or marked sensitive by the app is kept or offered. The history is the
 * newest first, pinned clips at the top, in files/clipboard.json.
 */
class Clipboard(context: Context, private val private: () -> Boolean) {
    class Clip(val text: String, val pinned: Boolean)

    private val app = context.applicationContext
    private val prefs = app.getSharedPreferences("keyboard", Context.MODE_PRIVATE)
    private val manager = app.getSystemService(ClipboardManager::class.java)
    private val file = File(app.filesDir, "clipboard.json")
    private val saver = Executors.newSingleThreadExecutor { Thread(it, "SebType clipboard") }

    /** Called when the history or the quick clip changes */
    var onChange: (() -> Unit)? = null

    /** Off after a fresh install, as today's keyboard */
    var keep: Boolean
        get() = prefs.getBoolean("keep_clipboard", false)
        set(value) {
            prefs.edit().putBoolean("keep_clipboard", value).apply()
            if (!value) clear(keepPinned = false)
            onChange?.invoke()
        }

    var history: List<Clip> = load()
        private set

    private var quick: String? = null
    private var quickAt = 0L

    /** The text copied in the last [QUICK_MS], until it is pasted or dismissed */
    val quickClip: String? get() = quick?.takeIf { SystemClock.elapsedRealtime() - quickAt < QUICK_MS }

    private val listener = ClipboardManager.OnPrimaryClipChangedListener { copied() }

    fun start() = manager.addPrimaryClipChangedListener(listener)
    fun stop() = manager.removePrimaryClipChangedListener(listener)

    private fun copied() {
        val clip = manager.primaryClip ?: return
        val description = clip.description
        if (Build.VERSION.SDK_INT >= 33 && description.extras?.getBoolean(ClipDescription.EXTRA_IS_SENSITIVE) == true) return
        if (private()) return
        val text = (0 until clip.itemCount).firstNotNullOfOrNull { clip.getItemAt(it).coerceToText(app)?.toString()?.ifBlank { null } } ?: return
        quick = text
        quickAt = SystemClock.elapsedRealtime()
        if (keep) {
            val pinned = history.any { it.text == text && it.pinned }
            update(listOf(Clip(text, pinned)) + history.filter { it.text != text })
        } else onChange?.invoke()
    }

    /** The quick clip is gone once used or dismissed. */
    fun dropQuick() {
        quick = null
        onChange?.invoke()
    }

    fun pin(clip: Clip, on: Boolean) = update(history.map { if (it === clip) Clip(it.text, on) else it })

    fun remove(clip: Clip) = update(history.filter { it !== clip })

    fun clear(keepPinned: Boolean = true) = update(if (keepPinned) history.filter { it.pinned } else emptyList())

    private fun update(clips: List<Clip>) {
        // Pinned first; at most MAX of the others, the oldest dropped.
        val pinned = clips.filter { it.pinned }
        history = pinned + clips.filter { !it.pinned }.take(MAX)
        val json = JSONArray(history.map { JSONObject().put("text", it.text).put("pinned", it.pinned) }).toString()
        saver.execute {
            val part = File(file.path + ".new")
            part.writeText(json)
            part.renameTo(file)
        }
        onChange?.invoke()
    }

    private fun load(): List<Clip> = try {
        if (!file.isFile) emptyList()
        else JSONArray(file.readText()).let { a ->
            (0 until a.length()).map { a.getJSONObject(it).let { o -> Clip(o.getString("text"), o.optBoolean("pinned")) } }
        }
    } catch (e: org.json.JSONException) {
        emptyList()
    }

    private companion object {
        const val MAX = 25
        const val QUICK_MS = 60_000L
    }
}

/**
 * The clipboard, in place of the keys: a switch to keep the history, then the clips as cream cards, pinned ones
 * first; a tap pastes one, its pin and × keep or drop it. With the history off, a note says so.
 */
@SuppressLint("ViewConstructor")
class ClipboardPanel(context: Context, private val texts: Texts, private val clipboard: Clipboard, private val onPaste: (String) -> Unit) :
    ItemsView(context, vertical = true) {
    private val density = resources.displayMetrics.density
    private val text = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 15 * density; color = Picnic.INK }
    private val muted = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = 15 * density; color = Picnic.MUTED }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val pad = 10 * density
    private val button = 40 * density
    private val layouts = HashMap<String, StaticLayout>()

    private class Card(val clip: Clipboard.Clip)
    private class Pin(val clip: Clipboard.Clip)
    private class Remove(val clip: Clipboard.Clip)
    private enum class Kind { KEEP, CLEAR, NOTE }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) = rebuild(false)

    fun show() = rebuild(true)

    private fun rebuild(keepScroll: Boolean) {
        if (width == 0) return
        layouts.clear()
        val out = ArrayList<Item>()
        var y = pad
        val row = 48 * density
        out += Item(RectF(pad, y, width - pad - 110 * density, y + row), texts[R.string.clipboard_keep], "android.widget.Switch",
            checked = clipboard.keep, tag = Kind.KEEP)
        if (clipboard.history.any { !it.pinned })
            out += Item(RectF(width - pad - 100 * density, y, width - pad, y + row), texts[R.string.clipboard_clear], "android.widget.Button", tag = Kind.CLEAR)
        y += row + pad
        if (clipboard.history.isEmpty()) {
            val note = texts[if (clipboard.keep) R.string.clipboard_empty else R.string.clipboard_off]
            out += Item(RectF(pad, y, width - pad, y + row), note, "android.widget.TextView", tag = Kind.NOTE)
            y += row
        }
        val textWidth = (width - 2 * pad - 2 * button - 16 * density).toInt()
        for (clip in clipboard.history) {
            val l = layout(clip.text, textWidth)
            val h = maxOf(l.height + 24 * density, 2 * button)
            out += Item(RectF(width - pad - 2 * button, y, width - pad - button, y + button),
                texts[if (clip.pinned) R.string.clipboard_unpin else R.string.clipboard_pin], "android.widget.Button", checked = clip.pinned, tag = Pin(clip))
            out += Item(RectF(width - pad - button, y, width - pad, y + button), texts[R.string.clipboard_remove], "android.widget.Button", tag = Remove(clip))
            // After its buttons, which a tap finds first; it draws them
            out += Item(RectF(pad, y, width - pad, y + h), clip.text, "android.widget.Button", tag = Card(clip))
            y += h + pad
        }
        setItems(out, y, keepScroll)
    }

    private fun layout(s: String, w: Int) = layouts.getOrPut(s) {
        StaticLayout.Builder.obtain(s, 0, s.length, text, w).setMaxLines(4).setEllipsize(TextUtils.TruncateAt.END).build()
    }

    override fun onTap(item: Item) {
        when (val tag = item.tag) {
            Kind.KEEP -> clipboard.keep = !clipboard.keep
            Kind.CLEAR -> clipboard.clear()
            is Pin -> clipboard.pin(tag.clip, !tag.clip.pinned)
            is Remove -> clipboard.remove(tag.clip)
            is Card -> onPaste(tag.clip.text)
        }
    }

    override fun drawItem(canvas: Canvas, item: Item) {
        val r = item.rect
        val radius = 15 * density
        when (val tag = item.tag) {
            Kind.KEEP -> {
                canvas.drawText(item.label, r.left + 4 * density, r.centerY() + text.textSize * 0.35f, text)
                val on = item.checked == true
                val sw = 44 * density
                val sh = 26 * density
                val sl = r.right - sw
                fill.color = if (on) Picnic.OUTLINE else Picnic.LINE
                canvas.drawRoundRect(sl, r.centerY() - sh / 2, sl + sw, r.centerY() + sh / 2, sh / 2, sh / 2, fill)
                fill.color = if (on) Picnic.CREAM else Picnic.OUTLINE
                canvas.drawCircle(if (on) sl + sw - sh / 2 else sl + sh / 2, r.centerY(), if (on) 9 * density else 7 * density, fill)
            }
            Kind.CLEAR -> {
                fill.color = Picnic.CREAM
                canvas.drawRoundRect(r.left, r.top + 6 * density, r.right, r.bottom - 6 * density, radius, radius, fill)
                muted.textAlign = Paint.Align.CENTER
                canvas.drawText(item.label, r.centerX(), r.centerY() + muted.textSize * 0.35f, muted)
                muted.textAlign = Paint.Align.LEFT
            }
            Kind.NOTE -> canvas.drawText(item.label, r.left + 4 * density, r.centerY() + muted.textSize * 0.35f, muted)
            is Card -> {
                fill.color = if (tag.clip.pinned) Picnic.PINK else Picnic.CREAM
                canvas.drawRoundRect(r.left, r.top, r.right, r.bottom, radius, radius, fill)
                canvas.save()
                canvas.translate(r.left + 12 * density, r.top + 12 * density)
                layout(tag.clip.text, (width - 2 * pad - 2 * button - 16 * density).toInt()).draw(canvas)
                canvas.restore()
                val cy = r.top + button / 2
                Icons.draw(canvas, Icons.Icon.PIN, r.right - 1.5f * button, cy, 18 * density, if (tag.clip.pinned) Picnic.BERRY else Picnic.MUTED)
                Icons.draw(canvas, Icons.Icon.CLOSE, r.right - button / 2, cy, 16 * density, Picnic.MUTED)
            }
        }
    }
}
