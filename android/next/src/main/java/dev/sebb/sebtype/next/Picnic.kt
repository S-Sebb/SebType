package dev.sebb.sebtype.next

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Shader
import android.graphics.Typeface
import androidx.core.content.res.ResourcesCompat
import kotlin.math.roundToInt

/**
 * SebType's one look, Picnic (#17, #111), in light and dark system mode alike: cream keys in notched brown
 * pixel frames with a hard shadow, on a checkered cloth, after SebChat's look. Every colour of the keyboard
 * window is here.
 */
object Picnic {
    const val CLOTH = 0xFFFFEBD6.toInt()
    const val CHECK = 0xFFF7E3CE.toInt()
    const val CREAM = 0xFFFFF7E8.toInt()
    const val INK = 0xFF4A2F22.toInt()
    const val MUTED = 0xFF73533F.toInt()
    /** The space bar's language name and the unselected kana of 日本語's chip */
    const val FADED = 0xFFB9A594.toInt()
    /** 中文's pinyin box over the app */
    const val PREEDIT = 0xFFA7A7A9.toInt()
    const val LINE = 0xFFECD0AE.toInt()
    const val WARM = 0xFFF0B443.toInt()
    const val PINK = 0xFFFDE0E6.toInt()
    const val PINK_LOW = 0xFFE7C9A4.toInt()
    const val OUTLINE = 0xFF5B331C.toInt()
    const val BERRY = 0xFFC2506A.toInt()
    const val BERRY_HIGH = 0xFFE8778F.toInt()
    const val BERRY_LOW = 0xFF92384E.toInt()
    const val SHADOW = 0x305B331C
    /** A resize held at a limit, as today's error colour */
    const val LIMIT = 0xFFD64541.toInt()
    const val WHITE = 0xFFFFFFFF.toInt()
    private const val PETAL_PINK = 0xFFF4B6C2.toInt()
    private const val PETAL_LILAC = 0xFFC9B6EF.toInt()

    /** One pixel of the look: frames are this thick, 2 dp in whole device pixels. */
    fun pixel(context: Context) = maxOf(1, (2 * context.resources.displayMetrics.density).roundToInt())

    private var fonts: Pair<Typeface, Typeface>? = null

    /** The keys' font (Nunito ExtraBold) and the popups' pixel font (Pixelify Sans), both OFL. */
    fun fonts(context: Context) = fonts ?: Pair(
        ResourcesCompat.getFont(context, R.font.sebtype_nunito_extrabold)!!,
        ResourcesCompat.getFont(context, R.font.sebtype_pixelify_semibold)!!,
    ).also { fonts = it }

    /**
     * The cloth: 64 look-pixels (1.5 dp each) checkered in two halves, with three tiny flowers. Drawn once
     * per density and repeated.
     */
    fun cloth(context: Context): Paint {
        val px = maxOf(1, (1.5f * context.resources.displayMetrics.density).roundToInt())
        val tile = Bitmap.createBitmap(64 * px, 64 * px, Bitmap.Config.RGB_565)
        val canvas = Canvas(tile)
        val paint = Paint()
        canvas.drawColor(CLOTH)
        paint.color = CHECK
        val half = 32f * px
        canvas.drawRect(0f, 0f, half, half, paint)
        canvas.drawRect(half, half, 2 * half, 2 * half, paint)
        fun dot(x: Int, y: Int, color: Int) {
            paint.color = color
            canvas.drawRect(x * px.toFloat(), y * px.toFloat(), (x + 1) * px.toFloat(), (y + 1) * px.toFloat(), paint)
        }
        for ((x, y, petals, middle) in listOf(
            Flower(10, 12, PETAL_PINK, WARM), Flower(44, 50, PETAL_LILAC, WARM), Flower(50, 16, PETAL_PINK, WHITE),
        )) {
            dot(x, y - 1, petals); dot(x - 1, y, petals); dot(x + 1, y, petals); dot(x, y + 1, petals)
            dot(x, y, middle)
        }
        return Paint().apply { shader = BitmapShader(tile, Shader.TileMode.REPEAT, Shader.TileMode.REPEAT) }
    }

    private data class Flower(val x: Int, val y: Int, val petals: Int, val middle: Int)
}

/**
 * A pixel frame: an outline with its corners notched out, a light edge top-left and a dark one bottom-right
 * inside it, and a hard shadow [w] pixels wide right and below. Pressed, the edges swap and the shadow goes,
 * as if the key were pushed in.
 */
class PixelFrame(
    val fill: Int,
    private val light: Int?,
    private val dark: Int?,
    private val shadow: Boolean = true,
    private val outline: Int = Picnic.OUTLINE,
) {
    private val paint = Paint()

    fun draw(canvas: Canvas, left: Float, top: Float, right: Float, bottom: Float, w: Float, pressed: Boolean = false) {
        // Whole pixels, so the frame stays crisp.
        val l = left.roundToInt().toFloat()
        val t = top.roundToInt().toFloat()
        val r = right.roundToInt() - w
        val b = bottom.roundToInt() - w
        fun rect(x0: Float, y0: Float, x1: Float, y1: Float, color: Int) {
            paint.color = color
            canvas.drawRect(x0, y0, x1, y1, paint)
        }
        if (shadow && !pressed) {
            rect(r, t + 3 * w, r + w, b + w, Picnic.SHADOW)
            rect(l + 3 * w, b, r, b + w, Picnic.SHADOW)
        }
        rect(l + w, t + w, r - w, b - w, fill)
        val (topLeft, bottomRight) = if (pressed) dark to light else light to dark
        bottomRight?.let {
            rect(l + w, b - 2 * w, r - w, b - w, it)
            rect(r - 2 * w, t + w, r - w, b - w, it)
        }
        topLeft?.let {
            rect(l + w, t + w, r - w, t + 2 * w, it)
            rect(l + w, t + w, l + 2 * w, b - w, it)
        }
        rect(l + w, t, r - w, t + w, outline)
        rect(l + w, b - w, r - w, b, outline)
        rect(l, t + w, l + w, b - w, outline)
        rect(r - w, t + w, r, b - w, outline)
    }

    companion object {
        /** A letter key */
        val CREAM = PixelFrame(Picnic.CREAM, Picnic.WHITE, Picnic.LINE)
        /** Shift, delete, symbols and the other function keys */
        val PINK = PixelFrame(Picnic.PINK, Picnic.WHITE, Picnic.PINK_LOW)
        /** Enter, and Shift while it is locked */
        val BERRY = PixelFrame(Picnic.BERRY, Picnic.BERRY_HIGH, Picnic.BERRY_LOW)
        /** The first candidate's chip: flat pink, no edges or shadow */
        val CHIP = PixelFrame(Picnic.PINK, null, null, shadow = false)
    }
}
