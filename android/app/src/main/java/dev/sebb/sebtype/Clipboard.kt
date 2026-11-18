package dev.sebb.sebtype

import android.annotation.SuppressLint
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.StaticLayout
import android.text.TextPaint
import android.text.TextUtils
import android.util.Log
import android.util.LruCache
import dev.sebb.sebtype.data.Prefs
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors

/**
 * What was copied: the clipboard history (#26, #53 B8), kept only while the user keeps it on, and the quick
 * clip, the text or image just copied, offered in the bar for [QUICK_MS]. Nothing copied in a private or
 * password field, while incognito is on (#31, #139) or marked sensitive by the app is kept or offered. As
 * the FUTO-based app did (Decisions #2): text and images (PNG, JPEG or WebP up to 10 MB, copied into
 * files/clipboardfiles/), unpinned clips gone after 72 hours, at most 25 of them and 40 MB of their images.
 * The history is in files/clipboard.json in that app's format, so an update from it keeps it.
 */
class Clipboard(context: Context, private val private: () -> Boolean) {
    /** One clip, as today's app saves it: its text, or (text null) an image in [dir] */
    class Clip(
        val text: String?,
        val pinned: Boolean,
        /** When it was copied, pasted or (un)pinned last, in ms */
        val timestamp: Long,
        val file: String? = null,
        val mimeTypes: List<String> = emptyList(),
        val sizeMb: Float? = null,
    ) {
        fun with(pinned: Boolean = this.pinned, timestamp: Long = this.timestamp) = Clip(text, pinned, timestamp, file, mimeTypes, sizeMb)
    }

    /** What was just copied: text, or an image the app that copied it serves */
    data class Quick(val text: String?, val uri: Uri?, val mimeTypes: List<String>)

    private val app = context.applicationContext
    private val manager = app.getSystemService(ClipboardManager::class.java)
    private val file = File(app.filesDir, "clipboard.json")
    val dir = File(app.filesDir, "clipboardfiles")
    private val saver = Executors.newSingleThreadExecutor { Thread(it, "SebType clipboard") }
    private val images = Images(dir)
    // Bumped when the history is cleared or turned off: an image still being copied in is then dropped.
    private var generation = 0
    private val main = Handler(Looper.getMainLooper())

    /** Called when the history or the quick clip changes */
    var onChange: (() -> Unit)? = null

    // The switch just tapped, until the settings file has it (Prefs writes in the background)
    private var tapped: Boolean? = null

    /** The settings' clipboard history ([Prefs.CLIPBOARD_HISTORY]): off after a fresh install, as today's keyboard */
    var keep: Boolean
        get() {
            val saved = Prefs[Prefs.CLIPBOARD_HISTORY]
            if (tapped == saved) tapped = null
            return tapped ?: saved
        }
        set(value) {
            tapped = value
            Prefs.set(app, Prefs.CLIPBOARD_HISTORY, value)
            if (!value) clear(keepPinned = false)
            onChange?.invoke()
        }

    /** Newest first */
    var history: List<Clip> = emptyList()
        private set

    init {
        // What expired since the last start goes from the file and its images too, as today's
        val saved = load()
        if (saved != null) {
            history = capped(pruned(saved, System.currentTimeMillis()) { it.sizeMb ?: imageFile(it)?.length()?.let { n -> n / (1024f * 1024f) } })
            save(history)
        }
    }

    private var quick: Quick? = null
    private var quickAt = 0L

    /** What was copied in the last [QUICK_MS], until it is pasted or dismissed */
    val quickClip: Quick? get() = quick?.takeIf { SystemClock.elapsedRealtime() - quickAt < QUICK_MS }

    private val listener = ClipboardManager.OnPrimaryClipChangedListener { copied() }

    fun start() = manager.addPrimaryClipChangedListener(listener)
    fun stop() = manager.removePrimaryClipChangedListener(listener)

    private fun copied() {
        val clip = try { manager.primaryClip } catch (e: Exception) { null } ?: return
        val description = clip.description
        if (Build.VERSION.SDK_INT >= 33 && description.extras?.getBoolean(ClipDescription.EXTRA_IS_SENSITIVE) == true) return
        if (private()) return
        val item = clip.getItemAt(0) ?: return
        val mimeTypes = (0 until description.mimeTypeCount).map { description.getMimeType(it) }
        val uri = item.uri
        // Text only if no URI is given, or a text type is (today's rule)
        val text = if (uri == null || mimeTypes.any { it.startsWith("text/") })
            item.coerceToText(app)?.toString()?.takeIf { it.isNotBlank() && it.length <= MAX_TEXT } else null
        val now = System.currentTimeMillis()
        if (text != null) {
            quick = Quick(text, null, mimeTypes)
            quickAt = SystemClock.elapsedRealtime()
            if (keep) {
                val pinned = history.any { it.text == text && it.pinned }
                update(listOf(Clip(text, pinned, now, mimeTypes = mimeTypes)) + history.filter { it.text != text })
            } else onChange?.invoke()
        } else if (uri != null && mimeTypes.any { it.startsWith("image/") }) {
            quick = Quick(null, uri, mimeTypes)
            quickAt = SystemClock.elapsedRealtime()
            onChange?.invoke()
            val copying = generation
            if (keep) saver.execute { saveImage(uri, mimeTypes, now, copying) }
        }
    }

    /** On the saver's thread: the image copied into [dir] by its MD5, with its thumbnail; then it heads the history. */
    private fun saveImage(uri: Uri, mimeTypes: List<String>, now: Long, copying: Int) {
        val mime = IMAGE_TYPES.keys.firstOrNull { it in mimeTypes } ?: return
        try {
            dir.mkdirs()
            val part = File(dir, "copying.part")
            val md5 = MessageDigest.getInstance("MD5")
            var size = 0L
            val read = app.contentResolver.openInputStream(uri)?.use { input ->
                part.outputStream().use { out ->
                    val buffer = ByteArray(8192)
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        size += n
                        if (size > MAX_IMAGE_BYTES) return@use false
                        md5.update(buffer, 0, n)
                        out.write(buffer, 0, n)
                    }
                    true
                }
            }
            if (read != true) {
                part.delete()
                return
            }
            val name = md5.digest().joinToString("") { "%02x".format(it) } + "." + IMAGE_TYPES.getValue(mime)
            val image = File(dir, name)
            images.adding(name)
            if (image.exists()) part.delete() else part.renameTo(image)
            thumbnail(image)
            main.post {
                // Not if the history was cleared or turned off meanwhile.
                if (copying == generation && keep) {
                    val pinned = history.any { it.file == name && it.pinned }
                    update(listOf(Clip(null, pinned, now, name, listOf(mime), size / (1024f * 1024f))) + history.filter { it.file != name })
                }
                // Queued after update()'s save: the image is kept until a saved history shows it.
                saver.execute { images.added(name) }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Can't keep a copied image", e)
        }
    }

    /** The clips a search finds: those whose text, or whose type (image/png), contains [query] */
    fun find(query: String) = find(history, query)

    /** The quick clip is gone once used or dismissed. */
    fun dropQuick() {
        quick = null
        onChange?.invoke()
    }

    /** Pasted: it stays where it is, its 72 hours from now */
    fun pasted(clip: Clip) {
        if (clip in history) update(history.map { if (it === clip) it.with(timestamp = System.currentTimeMillis()) else it })
    }

    // As today's: (un)pinning starts its 72 hours again, so an old clip unpinned by mistake isn't gone at once.
    fun pin(clip: Clip, on: Boolean) = update(history.map { if (it === clip) it.with(pinned = on, timestamp = System.currentTimeMillis()) else it })

    fun remove(clip: Clip) = update(history.filter { it !== clip })

    fun clear(keepPinned: Boolean = true) {
        generation++
        update(if (keepPinned) history.filter { it.pinned } else emptyList())
    }

    /** Clips past their time or over the limits are gone (when the panel opens, as today's) */
    fun prune() {
        val kept = pruned(history, System.currentTimeMillis()) { c -> c.sizeMb ?: imageFile(c)?.takeIf { it.isFile }?.let { it.length() / (1024f * 1024f) } }
        if (kept.size != history.size) update(kept)
    }

    fun imageFile(clip: Clip): File? = clip.file?.let { File(dir, it) }

    fun thumbnailFile(clip: Clip): File? = imageFile(clip)?.let { File(dir, it.name + THUMB) }

    private fun update(clips: List<Clip>) {
        history = capped(clips)
        save(history)
        onChange?.invoke()
    }

    /** The file written and the images no clip shows any more deleted, in the background */
    private fun save(clips: List<Clip>) {
        val json = encode(clips)
        val kept = referenced(clips)
        saver.execute {
            val part = File(file.path + ".new")
            part.writeText(json)
            part.renameTo(file)
            images.saved(kept)
        }
    }

    private fun referenced(clips: List<Clip>) = clips.mapNotNull { it.file }.flatMap { listOf(it, it + THUMB) }.toSet()

    /** The saved history, without images whose file is gone; null if there is none or it can't be read */
    private fun load(): List<Clip>? = try {
        if (!file.isFile) null
        else decode(file.readText(), System.currentTimeMillis()).filter { it.file == null || imageFile(it)!!.isFile }
    } catch (e: JSONException) {
        Log.w(TAG, "Can't read the clipboard history", e)
        null
    }

    /**
     * The image files in a directory, used on the saver's thread alone. An image being copied in stays until
     * the history that shows it is saved or its copy is dropped: a save queued while it was copied in, whose
     * list of images doesn't have it yet, mustn't delete it.
     */
    class Images(private val dir: File) {
        // Copies in flight by name: the same image copied twice has the same name.
        private val adding = mutableMapOf<String, Int>()
        private var kept = emptySet<String>()

        fun adding(name: String) {
            adding[name] = (adding[name] ?: 0) + 1
        }

        /** A copy of [name] is done: shown by the history saved before this, or dropped, and then it goes. */
        fun added(name: String) {
            val left = adding.getValue(name) - 1
            if (left > 0) adding[name] = left
            else {
                adding -= name
                if (name !in kept) listOf(name, name + THUMB).forEach { File(dir, it).delete() }
            }
        }

        /** After a save of a history showing [kept] (images and thumbnails): the other files go, but those being added. */
        fun saved(kept: Set<String>) {
            this.kept = kept
            dir.listFiles()?.forEach {
                if (it.name !in kept && it.name.removeSuffix(THUMB) !in adding && !it.name.endsWith(".part")) it.delete()
            }
        }
    }

    /** A thumbnail as today's: the image's middle square, 384 px, as JPEG; made once, beside it. */
    private fun thumbnail(image: File) {
        val thumb = File(image.parent, image.name + THUMB)
        if (thumb.exists()) return
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(image.path, bounds)
        val side = minOf(bounds.outWidth, bounds.outHeight)
        if (side <= 0) return
        var sample = 1
        while (side / (sample * 2) >= THUMB_SIZE) sample *= 2
        val bitmap = BitmapFactory.decodeFile(image.path, BitmapFactory.Options().apply { inSampleSize = sample }) ?: return
        val s = minOf(bitmap.width, bitmap.height)
        val square = Bitmap.createBitmap(bitmap, (bitmap.width - s) / 2, (bitmap.height - s) / 2, s, s)
        val scaled = Bitmap.createScaledBitmap(square, THUMB_SIZE, THUMB_SIZE, true)
        thumb.outputStream().use { scaled.compress(Bitmap.CompressFormat.JPEG, 85, it) }
    }

    companion object {
        private const val TAG = "SebType"
        const val MAX = 25
        const val HOURS = 72
        const val MAX_IMAGES_MB = 40f
        const val QUICK_MS = 60_000L
        private const val MAX_TEXT = 500_000
        private const val MAX_IMAGE_BYTES = 10L * 1024 * 1024
        private const val THUMB = ".thumb.jpg"
        private const val THUMB_SIZE = 384
        private val IMAGE_TYPES = linkedMapOf("image/png" to "png", "image/jpeg" to "jpg", "image/jpg" to "jpg", "image/webp" to "webp")

        /**
         * The saved history, newest first: today's file is oldest first; stage 4's (text and pinned only, no
         * timestamps, its clips counted as copied [now]) newest first. A clip that can't be read (not text, not
         * an image) is left out, not the whole history.
         */
        fun decode(json: String, now: Long): List<Clip> {
            val a = JSONArray(json)
            val todays = (0 until a.length()).any { a.optJSONObject(it)?.has("timestamp") == true }
            val clips = (0 until a.length()).mapNotNull { i ->
                val o = a.optJSONObject(i) ?: return@mapNotNull null
                val text = if (o.isNull("text")) null else o.optString("text")
                val file = if (o.isNull("backingFile")) null else o.optString("backingFile")
                if (text == null && file == null) return@mapNotNull null
                val types = o.optJSONArray("mimeTypes")?.let { t -> (0 until t.length()).map { t.optString(it) } }.orEmpty()
                val size = if (o.isNull("sizeMb")) null else o.optDouble("sizeMb").toFloat()
                Clip(text, o.optBoolean("pinned"), o.optLong("timestamp", now), file, types, size)
            }
            return if (todays) clips.asReversed() else clips
        }

        /** Pinned clips first, then at most [MAX] unpinned ones, the newest */
        fun capped(clips: List<Clip>): List<Clip> = clips.filter { it.pinned } + clips.filter { !it.pinned }.take(MAX)

        fun find(clips: List<Clip>, query: String): List<Clip> = if (query.isBlank()) emptyList() else clips.filter {
            it.text?.contains(query, ignoreCase = true) == true || it.mimeTypes.any { m -> m.contains(query, ignoreCase = true) }
        }

        /** As today's app saves them: oldest first */
        fun encode(clips: List<Clip>): String = JSONArray(clips.asReversed().map { c ->
            JSONObject().put("timestamp", c.timestamp).put("pinned", c.pinned).put("text", c.text ?: JSONObject.NULL)
                .put("uri", JSONObject.NULL).put("mimeTypes", JSONArray(c.mimeTypes))
                .apply { c.file?.let { put("backingFile", it) } }.apply { c.sizeMb?.let { put("sizeMb", it.toDouble()) } }
        }).toString()

        /**
         * Today's limits on the unpinned clips (newest first): none older than [HOURS], at most [MAX], and
         * their images at most [MAX_IMAGES_MB] together, the newest kept ([sizeMb]: an image's size, null if
         * unknown, which drops it as today's does).
         */
        fun pruned(clips: List<Clip>, now: Long, sizeMb: (Clip) -> Float?): List<Clip> {
            val since = now - HOURS * 3_600_000L
            var unpinned = 0
            var images = 0f
            return clips.filter { c ->
                if (c.pinned) return@filter true
                if (c.timestamp < since || ++unpinned > MAX) return@filter false
                if (c.file == null) return@filter true
                images += sizeMb(c) ?: return@filter false
                images <= MAX_IMAGES_MB
            }
        }
    }
}

/**
 * The clipboard, in place of the keys: a switch to keep the history, then the clips as cream cards, pinned ones
 * first, an image as its picture; a tap pastes one, its pin and × keep or drop it. With the history off, a
 * note says so. As [results] it shows a search's finds alone, over the keys that type the search.
 */
@SuppressLint("ViewConstructor")
class ClipboardPanel(context: Context, private val texts: Texts, private val clipboard: Clipboard, private val results: Boolean = false,
                     private val onPaste: (Clipboard.Clip) -> Unit) : ItemsView(context, vertical = true) {
    private val density = resources.displayMetrics.density
    // Not density inside apply: TextPaint has a density of its own (1)
    private val fontSize = 15 * density
    private val text = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = fontSize; color = Picnic.INK }
    private val muted = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = fontSize; color = Picnic.MUTED }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val pad = 10 * density
    private val button = 40 * density
    private val imageHeight = 120 * density
    private val layouts = HashMap<String, StaticLayout>()
    private val thumbs = LruCache<String, Bitmap>(20)
    private val clip = Path()

    /** What the search is for: its results show */
    var query = ""
        set(value) {
            field = value
            rebuild(false)
        }

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
        val clips = if (results) clipboard.find(query) else clipboard.history
        if (!results) {
            out += Item(RectF(pad, y, width - pad - 110 * density, y + row), texts[R.string.clipboard_keep], "android.widget.Switch",
                checked = clipboard.keep, tag = Kind.KEEP)
            if (clipboard.history.any { !it.pinned })
                out += Item(RectF(width - pad - 100 * density, y, width - pad, y + row), texts[R.string.clipboard_clear], "android.widget.Button", tag = Kind.CLEAR)
            y += row + pad
        }
        val note = when {
            results -> if (clips.isEmpty() && query.isNotBlank() && clipboard.history.isNotEmpty()) texts[R.string.emoji_no_results] else null
            clipboard.history.isEmpty() -> texts[if (clipboard.keep) R.string.clipboard_empty else R.string.clipboard_off]
            else -> null
        }
        if (note != null) {
            out += Item(RectF(pad, y, width - pad, y + row), note, "android.widget.TextView", tag = Kind.NOTE)
            y += row
        }
        val textWidth = (width - 2 * pad - 2 * button - 16 * density).toInt()
        for (clip in clips) {
            val h = if (clip.text == null) imageHeight else maxOf(layout(clip.text, textWidth).height + 24 * density, 2 * button)
            out += Item(RectF(width - pad - 2 * button, y, width - pad - button, y + button),
                texts[if (clip.pinned) R.string.clipboard_unpin else R.string.clipboard_pin], "android.widget.Button", checked = clip.pinned, tag = Pin(clip))
            out += Item(RectF(width - pad - button, y, width - pad, y + button), texts[R.string.clipboard_remove], "android.widget.Button", tag = Remove(clip))
            // After its buttons, which a tap finds first; it draws them
            out += Item(RectF(pad, y, width - pad, y + h), clip.text ?: texts[R.string.clipboard_image], "android.widget.Button", tag = Card(clip))
            y += h + pad
        }
        setItems(out, y, keepScroll)
    }

    private fun layout(s: String, w: Int) = layouts.getOrPut(s) {
        StaticLayout.Builder.obtain(s, 0, s.length, text, w).setMaxLines(4).setEllipsize(TextUtils.TruncateAt.END).build()
    }

    private fun thumb(c: Clipboard.Clip): Bitmap? {
        val f = clipboard.thumbnailFile(c) ?: return null
        return thumbs.get(f.name) ?: BitmapFactory.decodeFile(f.path)?.also { thumbs.put(f.name, it) }
    }

    override fun onTap(item: Item) {
        when (val tag = item.tag) {
            Kind.KEEP -> clipboard.keep = !clipboard.keep
            Kind.CLEAR -> clipboard.clear()
            is Pin -> clipboard.pin(tag.clip, !tag.clip.pinned)
            is Remove -> clipboard.remove(tag.clip)
            is Card -> onPaste(tag.clip)
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
                val c = tag.clip
                if (c.text != null) {
                    canvas.save()
                    canvas.translate(r.left + 12 * density, r.top + 12 * density)
                    layout(c.text, (width - 2 * pad - 2 * button - 16 * density).toInt()).draw(canvas)
                    canvas.restore()
                } else {
                    // Its square thumbnail at the card's left, as tall as the card
                    val square = RectF(r.left, r.top, r.left + r.height(), r.bottom)
                    val bitmap = thumb(c)
                    if (bitmap != null) {
                        canvas.save()
                        clip.reset()
                        clip.addRoundRect(square, floatArrayOf(radius, radius, 0f, 0f, 0f, 0f, radius, radius), Path.Direction.CW)
                        canvas.clipPath(clip)
                        canvas.drawBitmap(bitmap, null, square, null)
                        canvas.restore()
                    } else Icons.draw(canvas, Icons.Icon.IMAGE, square.centerX(), square.centerY(), 32 * density, Picnic.MUTED)
                }
                val cy = r.top + button / 2
                Icons.draw(canvas, Icons.Icon.PIN, r.right - 1.5f * button, cy, 18 * density, if (c.pinned) Picnic.BERRY else Picnic.MUTED)
                Icons.draw(canvas, Icons.Icon.CLOSE, r.right - button / 2, cy, 16 * density, Picnic.MUTED)
            }
        }
    }
}
