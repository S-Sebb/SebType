package org.futo.inputmethod.latin.uix.theme.presets

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.ColorFilter
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Rect
import android.graphics.drawable.Drawable
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.tooling.preview.Preview
import androidx.core.content.res.ResourcesCompat
import org.futo.inputmethod.latin.R
import org.futo.inputmethod.latin.uix.KeyboardColorScheme
import org.futo.inputmethod.latin.uix.extendedLightColorScheme
import org.futo.inputmethod.latin.uix.theme.KeyBackground
import org.futo.inputmethod.latin.uix.theme.KeyQualifier
import org.futo.inputmethod.latin.uix.theme.KeyedBitmap
import org.futo.inputmethod.latin.uix.theme.KeyedBitmaps
import org.futo.inputmethod.latin.uix.theme.ThemeOption
import org.futo.inputmethod.latin.uix.theme.selector.ThemePreview
import org.futo.inputmethod.v2keyboard.KeyVisualStyle
import kotlin.math.roundToInt

// SebType's "Picnic" theme: SebChat's pixel look (S-Sebb/SebChat app/lib/look.dart). Cream keys in
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
 *  top-left and lowlight bottom-right inside, and a hard shadow in the last [w] pixels right and below. */
private class PixelFrame(
    private val fill: Int,
    private val highlight: Int?,
    private val lowlight: Int?,
    private val w: Int,
    private val shadow: Boolean,
) : Drawable() {
    private val paint = Paint().apply { isAntiAlias = false }

    /** Pushed in: the bevel flips and the shadow goes, as SebChat's buttons do. */
    fun pressed() = PixelFrame(fill, lowlight, highlight, w, false)

    override fun draw(canvas: Canvas) {
        val b = bounds
        val l = b.left.toFloat(); val t = b.top.toFloat()
        val r = (b.right - w).toFloat(); val btm = (b.bottom - w).toFloat()
        fun rect(x0: Float, y0: Float, x1: Float, y1: Float, color: Int) {
            paint.color = color
            canvas.drawRect(x0, y0, x1, y1, paint)
        }
        if (shadow) {
            rect(r, t + 3 * w, r + w, btm + w, Picnic.drop)
            rect(l + 3 * w, btm, r, btm + w, Picnic.drop)
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
        rect(l + w, t, r - w, t + w, Picnic.outline)
        rect(l + w, btm - w, r - w, btm, Picnic.outline)
        rect(l, t + w, l + w, btm - w, Picnic.outline)
        rect(r - w, t + w, r, btm - w, Picnic.outline)
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

/** SebChat's cloth: a 64-pixel tile checkered in two halves with three tiny flowers, one pixel being
 *  1.5 dp rounded to whole device pixels. Sized to the screen so FUTO draws it unscaled. */
private fun cloth(context: Context): Bitmap {
    val metrics = context.resources.displayMetrics
    val px = maxOf(1, (1.5f * metrics.density).roundToInt())
    val tile = 64 * px
    val bitmap = Bitmap.createBitmap(metrics.widthPixels, (metrics.heightPixels * 0.6f).roundToInt(), Bitmap.Config.RGB_565)
    val canvas = Canvas(bitmap)
    val paint = Paint().apply { isAntiAlias = false }
    canvas.drawColor(Picnic.background)
    val flowers = listOf(
        Triple(10 to 12, 0xFFF4B6C2.toInt(), Picnic.warm),
        Triple(44 to 50, 0xFFC9B6EF.toInt(), Picnic.warm),
        Triple(50 to 16, 0xFFF4B6C2.toInt(), Picnic.white),
    )
    fun dot(x: Int, y: Int, color: Int) {
        paint.color = color
        canvas.drawRect((x * px).toFloat(), (y * px).toFloat(), ((x + 1) * px).toFloat(), ((y + 1) * px).toFloat(), paint)
    }
    for (top in 0 until bitmap.height step tile) for (left in 0 until bitmap.width step tile) {
        val half = tile / 2f
        paint.color = Picnic.check
        canvas.drawRect(left.toFloat(), top.toFloat(), left + half, top + half, paint)
        canvas.drawRect(left + half, top + half, left + 2 * half, top + 2 * half, paint)
        val tx = left / px; val ty = top / px
        for ((at, petals, middle) in flowers) {
            val (x, y) = at
            for ((dx, dy) in listOf(0 to -1, -1 to 0, 1 to 0, 0 to 1)) dot(tx + x + dx, ty + y + dy, petals)
            dot(tx + x, ty + y, middle)
        }
    }
    return bitmap
}

private fun keyBackgrounds(context: Context): KeyedBitmaps<KeyBackground> {
    val density = context.resources.displayMetrics.density
    val w = maxOf(1, (2 * density).roundToInt())
    val cream = PixelFrame(Picnic.surface, Picnic.white, Picnic.line, w, true)
    val pinkKey = PixelFrame(Picnic.pink, Picnic.white, Picnic.buttonLow, w, true)
    val berry = PixelFrame(Picnic.key, Picnic.keyHigh, Picnic.keyLow, w, true)
    val popup = PixelFrame(Picnic.surface, Picnic.white, Picnic.line, w + maxOf(1, density.roundToInt()), true)

    // Keeps the number hints inside the frame and clear of its shadow.
    val hintPadding = Rect(0, 3 * w, 4 * w, 0)
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

val PicnicTheme = ThemeOption(
    dynamic = false,
    key = "SebTypePicnic",
    name = R.string.sebtype_theme_picnic,
    available = { true }
) { context ->
    val m = context.resources.displayMetrics
    val size = Triple(m.widthPixels, m.heightPixels, m.density)
    cached?.takeIf { it.first == size }?.second ?: run {
        val image = cloth(context).asImageBitmap()
        scheme.copy(extended = scheme.extended.copy(
            // Draws over the cloth; clear so the cloth shows.
            keyboardBackgroundGradient = SolidColor(Color.Transparent),
            advancedThemeOptions = scheme.extended.advancedThemeOptions.copy(
                backgroundImage = image,
                backgroundImageVisibleArea = Rect(0, 0, image.width, image.height),
                thumbnailImage = image,
                actionBarOpacity = 0f,
                keyBorders = true,
                // Nunito's letters are wide; this brings them to the size of FUTO's default font.
                textSizeMultiplier = 0.85f,
                keyBackgrounds = keyBackgrounds(context),
                font = ResourcesCompat.getFont(context, R.font.sebtype_nunito_extrabold),
            )
        )).also { cached = size to it }
    }
}

@Composable
@Preview
private fun PreviewPicnic() {
    ThemePreview(PicnicTheme)
}
