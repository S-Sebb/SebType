package dev.sebb.sebtype.next

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.text.Editable
import android.text.Selection
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.TextWatcher
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.text.InputType

/**
 * The emoji and clipboard panels' search (#281), as today's: the keys type into a search field over the
 * results, in any of the three languages (the engines compose into it as into a field), and the results
 * follow each key. [connection] is what the search's [Editor] types into.
 */
class Search(view: View, private val onChange: (String) -> Unit) {
    val text: Editable = SpannableStringBuilder()

    /** A plain text field that learns nothing and corrects nothing */
    val info = EditorInfo().apply {
        inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        imeOptions = EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING or EditorInfo.IME_ACTION_SEARCH
        initialSelStart = 0
        initialSelEnd = 0
    }

    val connection = object : BaseInputConnection(view, true) {
        override fun getEditable() = text
        // Enter does nothing: the results already follow the keys.
        override fun performEditorAction(actionCode: Int) = true
    }

    init {
        text.setSpan(object : TextWatcher {
            override fun beforeTextChanged(s: CharSequence, start: Int, count: Int, after: Int) {}
            override fun onTextChanged(s: CharSequence, start: Int, before: Int, count: Int) {}
            override fun afterTextChanged(s: Editable) = view.post { onChange(text.toString()) }.let {}
        }, 0, 0, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
    }

    fun clear() {
        text.clear()
        Selection.setSelection(text, 0)
    }
}

/**
 * Over a search's results, as today's: ← (back to the keys) and the search field, a cream pill with what is
 * typed (or a hint) and the cursor.
 */
@SuppressLint("ViewConstructor")
class SearchRow(context: Context, private val texts: Texts, private val onClose: () -> Unit) : ItemsView(context, vertical = false) {
    private val density = resources.displayMetrics.density
    private val rowHeight = (48 * density).toInt()
    private val text = Paint(Paint.ANTI_ALIAS_FLAG).apply { typeface = Picnic.fonts(context).first; textSize = 16 * density; color = Picnic.INK }
    private val hint = Paint(text).apply { color = Picnic.MUTED }
    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private var query = ""
    private var placeholder = ""

    private enum class Kind { BACK, FIELD }

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) =
        setMeasuredDimension(MeasureSpec.getSize(widthMeasureSpec), rowHeight)

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) = rebuild()

    fun show(query: String, placeholder: String) {
        this.query = query
        this.placeholder = placeholder
        rebuild()
    }

    private fun rebuild() {
        if (width == 0) return
        val h = height.toFloat()
        val back = 45 * density
        setItems(listOf(
            Item(RectF(0f, 0f, back, h), texts[R.string.search_close], "android.widget.Button", fixed = true, tag = Kind.BACK),
            Item(RectF(back, 0f, width.toFloat(), h), query.ifEmpty { placeholder }, "android.widget.EditText", fixed = true, tag = Kind.FIELD),
        ), 0f)
    }

    override fun onDraw(canvas: Canvas) {
        canvas.drawColor(Picnic.CLOTH)
        super.onDraw(canvas)
    }

    override fun onTap(item: Item) {
        if (item.tag == Kind.BACK) onClose()
    }

    override fun drawItem(canvas: Canvas, item: Item) {
        val r = item.rect
        val cy = r.centerY()
        when (item.tag) {
            Kind.BACK -> Icons.draw(canvas, Icons.Icon.PREVIOUS, r.centerX(), cy, 22 * density, Picnic.INK)
            Kind.FIELD -> {
                val half = 20 * density
                fill.color = Picnic.CREAM
                canvas.drawRoundRect(r.left + 2 * density, cy - half, r.right - 8 * density, cy + half, half, half, fill)
                val x = r.left + 18 * density
                val y = cy + text.textSize * 0.35f
                if (query.isEmpty()) canvas.drawText(placeholder, x, y, hint)
                else {
                    // The end of a long search shows, where the cursor is
                    val room = r.width() - 40 * density
                    val shown = query.takeLast(text.breakText(query, false, room, null))
                    canvas.drawText(shown, x, y, text)
                    val end = x + text.measureText(shown) + 2 * density
                    fill.color = Picnic.INK
                    canvas.drawRect(end, cy - 10 * density, end + 1.5f * density, cy + 10 * density, fill)
                }
            }
        }
    }
}
