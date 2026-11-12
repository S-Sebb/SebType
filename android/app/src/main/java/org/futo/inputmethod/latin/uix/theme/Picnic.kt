package org.futo.inputmethod.latin.uix.theme

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapShader
import android.graphics.Canvas
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.Shader
import android.graphics.drawable.Drawable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.core.content.res.ResourcesCompat
import org.futo.inputmethod.latin.R
import org.futo.inputmethod.latin.uix.KeyboardColorScheme
import org.futo.inputmethod.latin.uix.extendedLightColorScheme
import org.futo.inputmethod.v2keyboard.KeyVisualStyle
import kotlin.math.roundToInt

// SebType's one look, "Picnic" (#17, #111), in light and dark system mode alike: SebChat's pixel look (S-Sebb/SebChat app/lib/look.dart). Cream keys in
// notched brown frames with a hard shadow, on SebChat's checkered cloth at half its size (48 dp checks).
private object Picnic {
    const val background = 0xFFFBE9D6.toInt()
    const val check = 0xFFF8E2CC.toInt()
    const val surface = 0xFFFFF7E8.toInt()
    const val ink = 0xFF4A2F22.toInt()
    const val muted = 0xFF73533F.toInt()
    const val line = 0xFFECD0AE.toInt()
    const val warm = 0xFFF0B443.toInt()
    const val pink = 0xFFFDE0E6.toInt()
    const val outline = 0xFF5B331C.toInt()
    const val buttonLow = 0xFFE7C9A4.toInt()
    const val key = 0xFFC2506A.toInt()
    const val keyHigh = 0xFFE8778F.toInt()
    const val keyLow = 0xFF92384E.toInt()
    const val drop = 0x305B331C
    const val white = 0xFFFFFFFF.toInt()
}

/** SebChat's PixelBorder as a drawable: an outline with square corners cut away, a highlight
 *  top-left and lowlight bottom-right inside, and a hard shadow in the last [w] pixels right and below.
 *  The settings' cards use it too (settings/PixelLook.kt). */
internal class PixelFrame(
    private val fill: Int,
    private val highlight: Int?,
    private val lowlight: Int?,
    private val w: Int,
    private val shadow: Boolean,
    private val outline: Int = Picnic.outline,
    private val drop: Int = Picnic.drop,
) : Drawable() {
    private val paint = Paint().apply { isAntiAlias = false }

    /** Pushed in: the bevel flips and the shadow goes, as SebChat's buttons do. */
    fun pressed() = PixelFrame(fill, lowlight, highlight, w, false, outline, drop)

    override fun draw(canvas: Canvas) {
        val b = bounds
        val l = b.left.toFloat(); val t = b.top.toFloat()
        val r = (b.right - w).toFloat(); val btm = (b.bottom - w).toFloat()
        fun rect(x0: Float, y0: Float, x1: Float, y1: Float, color: Int) {
            paint.color = color
            canvas.drawRect(x0, y0, x1, y1, paint)
        }
        if (shadow) {
            rect(r, t + 3 * w, r + w, btm + w, drop)
            rect(l + 3 * w, btm, r, btm + w, drop)
        }
        rect(l + w, t + w, r - w, btm - w, fill)
        lowlight?.let {
            rect(l + w, btm - 2 * w, r - w, btm - w, it)
            rect(r - 2 * w, t + w, r - w, btm - w, it)
        }
        highlight?.let {
            rect(l + w, t + w, r - w, t + 2 * w, it)
            rect(l + w, t + w, l + 2 * w, btm - w, it)
        }
        rect(l + w, t, r - w, t + w, outline)
        rect(l + w, btm - w, r - w, btm, outline)
        rect(l, t + w, l + w, btm - w, outline)
        rect(r - w, t + w, r, btm - w, outline)
    }

    override fun getPadding(padding: Rect): Boolean { padding.setEmpty(); return false }
    override fun setAlpha(alpha: Int) {}
    override fun setColorFilter(colorFilter: ColorFilter?) {}
    @Deprecated("Deprecated in Java")
    override fun getOpacity() = PixelFormat.TRANSLUCENT
}

private class Clear : Drawable() {
    override fun draw(canvas: Canvas) {}
    override fun setAlpha(alpha: Int) {}
    override fun setColorFilter(colorFilter: ColorFilter?) {}
    @Deprecated("Deprecated in Java")
    override fun getOpacity() = PixelFormat.TRANSPARENT
}

/** SebChat's cloth tile: 64 pixels checkered in two halves with three tiny flowers, one pixel being
 *  1.5 dp rounded to whole device pixels. The settings page repeats it too. */
internal fun clothTile(density: Float, background: Int, check: Int): Bitmap {
    val px = maxOf(1, (1.5f * density).roundToInt())
    val half = 32f * px
    val bitmap = Bitmap.createBitmap(64 * px, 64 * px, Bitmap.Config.RGB_565)
    val canvas = Canvas(bitmap)
    val paint = Paint().apply { isAntiAlias = false }
    canvas.drawColor(background)
    paint.color = check
    canvas.drawRect(0f, 0f, half, half, paint)
    canvas.drawRect(half, half, 2 * half, 2 * half, paint)
    fun dot(x: Int, y: Int, color: Int) {
        paint.color = color
        canvas.drawRect((x * px).toFloat(), (y * px).toFloat(), ((x + 1) * px).toFloat(), ((y + 1) * px).toFloat(), paint)
    }
    val flowers = listOf(
        Triple(10 to 12, 0xFFF4B6C2.toInt(), Picnic.warm),
        Triple(44 to 50, 0xFFC9B6EF.toInt(), Picnic.warm),
        Triple(50 to 16, 0xFFF4B6C2.toInt(), Picnic.white),
    )
    for ((at, petals, middle) in flowers) {
        val (x, y) = at
        for ((dx, dy) in listOf(0 to -1, -1 to 0, 1 to 0, 0 to 1)) dot(x + dx, y + dy, petals)
        dot(x, y, middle)
    }
    return bitmap
}

/** The cloth for the keyboard, sized to the screen so FUTO draws it unscaled. */
private fun cloth(context: Context): Bitmap {
    val metrics = context.resources.displayMetrics
    val bitmap = Bitmap.createBitmap(metrics.widthPixels, (metrics.heightPixels * 0.6f).roundToInt(), Bitmap.Config.RGB_565)
    val tile = clothTile(metrics.density, Picnic.background, Picnic.check)
    Canvas(bitmap).drawPaint(Paint().apply { shader = BitmapShader(tile, Shader.TileMode.REPEAT, Shader.TileMode.REPEAT) })
    return bitmap
}

/** The key frames' line: 2 dp in whole device pixels. */
private fun frameWidth(density: Float) = maxOf(1, (2 * density).roundToInt())

private fun keyBackgrounds(context: Context): KeyedBitmaps<KeyBackground> {
    val density = context.resources.displayMetrics.density
    val w = frameWidth(density)
    val cream = PixelFrame(Picnic.surface, Picnic.white, Picnic.line, w, true)
    val pinkKey = PixelFrame(Picnic.pink, Picnic.white, Picnic.buttonLow, w, true)
    val berry = PixelFrame(Picnic.key, Picnic.keyHigh, Picnic.keyLow, w, true)
    val popup = PixelFrame(Picnic.surface, Picnic.white, Picnic.line, w + maxOf(1, density.roundToInt()), true)

    // Tucks the number hints into the frame's corner, clear of its bevel and shadow and of the letter.
    val hintPadding = Rect(0, 2 * w, 3 * w, 0)
    fun entry(background: Drawable, foreground: Int?, vararg q: KeyQualifier) =
        KeyedBitmap(q.toSet(), KeyBackground(foregroundColor = foreground, outlineColor = null, padding = hintPadding, background = background))
    fun style(s: KeyVisualStyle) = KeyQualifier.VisualStyle(s)
    val pressed = KeyQualifier.Pressed

    // First match wins, so pressed entries come before their style's resting one.
    return KeyedBitmaps(listOf(
        entry(popup, Picnic.ink, KeyQualifier.Popup),
        entry(popup, null, KeyQualifier.MoreKeysKeyboardBackground),
        entry(berry.pressed(), Picnic.white, style(KeyVisualStyle.MoreKey), pressed),
        entry(Clear(), Picnic.ink, style(KeyVisualStyle.MoreKey)),
        entry(Clear(), null, style(KeyVisualStyle.NoBackground)),
        entry(berry.pressed(), Picnic.white, style(KeyVisualStyle.Action), pressed),
        entry(berry, Picnic.white, style(KeyVisualStyle.Action)),
        entry(berry.pressed(), Picnic.white, style(KeyVisualStyle.StickyOn), pressed),
        entry(berry, Picnic.white, style(KeyVisualStyle.StickyOn)),
        entry(pinkKey.pressed(), null, style(KeyVisualStyle.Functional), pressed),
        entry(pinkKey, null, style(KeyVisualStyle.Functional)),
        entry(cream.pressed(), null, pressed),
        entry(cream, null),
    ))
}

private val scheme = extendedLightColorScheme(
    primary = Color(Picnic.key),
    onPrimary = Color.White,
    primaryContainer = Color(Picnic.pink),
    onPrimaryContainer = Color(Picnic.ink),
    secondary = Color(Picnic.key),
    onSecondary = Color.White,
    secondaryContainer = Color(Picnic.keyLow),
    onSecondaryContainer = Color.White,
    tertiary = Color(Picnic.warm),
    onTertiary = Color(Picnic.ink),
    tertiaryContainer = Color(Picnic.pink),
    onTertiaryContainer = Color(Picnic.ink),
    error = Color(0xFFA8322D),
    onError = Color.White,
    errorContainer = Color(Picnic.pink),
    onErrorContainer = Color(0xFFA8322D),
    outline = Color(Picnic.outline),
    outlineVariant = Color(Picnic.line),
    surface = Color(Picnic.surface),
    onSurface = Color(Picnic.ink),
    onSurfaceVariant = Color(Picnic.muted),
    surfaceContainerHighest = Color(Picnic.line),
    shadow = Color(Picnic.outline),
    keyboardSurface = Color(Picnic.background),
    keyboardContainer = Color(Picnic.surface),
    keyboardContainerVariant = Color(Picnic.pink),
    onKeyboardContainer = Color(Picnic.ink),
    keyboardPress = Color(Picnic.surface),
    primaryTransparent = Color(Picnic.key).copy(alpha = 0.3f),
    onSurfaceTransparent = Color(Picnic.ink).copy(alpha = 0.1f),
    navigationBarColor = Color(Picnic.background),
    hintColor = Color(Picnic.muted),
)

// The cloth is screen-sized, so it is made once per screen size and density.
private var cached: Pair<Triple<Int, Int, Float>, KeyboardColorScheme>? = null

/** The keyboard's and the settings' colours, cloth and key frames. */
fun picnicColors(context: Context): KeyboardColorScheme {
    val m = context.resources.displayMetrics
    val size = Triple(m.widthPixels, m.heightPixels, m.density)
    return cached?.takeIf { it.first == size }?.second ?: run {
        val image = cloth(context).asImageBitmap()
        scheme.copy(extended = scheme.extended.copy(
            // Draws over the cloth; clear so the cloth shows.
            keyboardBackgroundGradient = SolidColor(Color.Transparent),
            advancedThemeOptions = scheme.extended.advancedThemeOptions.copy(
                backgroundImage = image,
                backgroundImageVisibleArea = Rect(0, 0, image.width, image.height),
                actionBarOpacity = 0f,
                keyBorders = true,
                // Nearly Gboard's letter size (#161); Nunito ExtraBold is wider and heavier than
                // Gboard's font, so its capitals stay a little lower (47 px to 51 on a 420 dpi phone).
                textSizeMultiplier = 0.95f,
                keyBackgrounds = keyBackgrounds(context),
                font = ResourcesCompat.getFont(context, R.font.sebtype_nunito_extrabold),
                // SebChat's button font.
                popupFont = ResourcesCompat.getFont(context, R.font.sebtype_pixelify_semibold),
                // SebChat's chip: a flat pink frame, no bevel or shadow.
                candidateChip = PixelFrame(Picnic.pink, null, null, frameWidth(m.density), false),
            )
        )).also { cached = size to it }
    }
}
