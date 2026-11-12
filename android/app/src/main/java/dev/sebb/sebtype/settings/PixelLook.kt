package dev.sebb.sebtype.settings

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ImageShader
import androidx.compose.ui.graphics.ShaderBrush
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.times
import org.futo.inputmethod.latin.uix.LocalKeyboardScheme
import org.futo.inputmethod.latin.uix.theme.Typography
import org.futo.inputmethod.latin.uix.theme.PixelFrame
import org.futo.inputmethod.latin.uix.theme.clothTile
import kotlin.math.roundToInt

// SebType's settings look (#87, "C, pixel frames"): items sit in the Picnic keys' notched pixel frames
// on the checkered cloth, with pink tags as section headers. Every part of the look is in this file.
// Colours come from MaterialTheme, which is always Picnic's (#111).

/** Inside a card, section titles stay plain text instead of becoming tags (sliders and radio lists). */
internal val LocalInCard = staticCompositionLocalOf { false }

/** Frames are as thick as the keys' frames, in whole pixels. */
@Composable
private fun frameWidth() = maxOf(1, (2 * LocalDensity.current.density).roundToInt())

@Composable
private fun rememberFrame(fill: Color): PixelFrame {
    val c = MaterialTheme.colorScheme
    val w = frameWidth()
    return remember(fill, c, w) {
        PixelFrame(
            fill.toArgb(), lerp(fill, Color.White, 0.85f).toArgb(), c.outlineVariant.toArgb(), w, true,
            c.outline.toArgb(), c.outline.copy(alpha = 0x30 / 255f).toArgb()
        )
    }
}

private fun Modifier.pixelFrame(frame: PixelFrame) = drawBehind {
    drawIntoCanvas {
        frame.setBounds(0, 0, size.width.roundToInt(), size.height.roundToInt())
        frame.draw(it.nativeCanvas)
    }
}

/** Draws a pixel frame filled with [fill] behind the content, which keeps clear of the frame's outline
 *  and bevel and of its shadow on the end and bottom sides. */
@Composable
fun Modifier.framed(fill: Color, horizontal: Dp = 0.dp, vertical: Dp = 0.dp): Modifier {
    val px = with(LocalDensity.current) { frameWidth().toDp() }
    return pixelFrame(rememberFrame(fill))
        .padding(start = 2 * px + horizontal, top = 2 * px + vertical, end = 3 * px + horizontal, bottom = 3 * px + vertical)
}

/** The page behind every settings screen: the keyboard's cloth, repeated, in Picnic's colours. */
@Composable
fun Modifier.settingsCloth(): Modifier {
    val page = LocalKeyboardScheme.current.keyboardSurface
    val check = lerp(page, MaterialTheme.colorScheme.outlineVariant, 0.25f)
    val density = LocalDensity.current.density
    val brush = remember(page, check, density) {
        ShaderBrush(ImageShader(clothTile(density, page.toArgb(), check.toArgb()).asImageBitmap(), TileMode.Repeated, TileMode.Repeated))
    }
    return background(brush)
}

/** The dashed line between a card's rows: one rect painted with a repeated dash and gap, so a long
 *  list redraws a rect per row while scrolling rather than a rect per dash. */
@Composable
private fun rememberDashes(w: Int): ShaderBrush {
    val color = MaterialTheme.colorScheme.outlineVariant.toArgb()
    return remember(color, w) {
        val dash = (3 * w + 1) / 2
        val tile = Bitmap.createBitmap(2 * dash, w, Bitmap.Config.ARGB_8888)
        for(x in 0 until dash) for(y in 0 until w) tile.setPixel(x, y, color)
        ShaderBrush(ImageShader(tile.asImageBitmap(), TileMode.Repeated, TileMode.Repeated))
    }
}

private fun DrawScope.dashedLine(dashes: ShaderBrush, w: Int, y: Float, from: Float, to: Float) =
    drawRect(dashes, Offset(from, y), Size(to - from, w.toFloat()))

/** A framed card holding settings rows, with a dashed line between rows. */
@Composable
fun SettingsCard(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val w = frameWidth()
    val dashes = rememberDashes(w)
    var lines by remember { mutableStateOf(emptyList<Int>()) }
    val inset = with(LocalDensity.current) { 14.dp.toPx() }
    Layout(
        content = { CompositionLocalProvider(LocalInCard provides true, content = content) },
        modifier = modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, bottom = 12.dp)
            .framed(MaterialTheme.colorScheme.surface)
            .drawBehind { for(y in lines) dashedLine(dashes, w, y.toFloat(), inset, size.width - inset) }
    ) { measurables, constraints ->
        val rows = measurables.map { it.measure(constraints.copy(minHeight = 0)) }
        val tops = rows.runningFold(0) { y, row -> y + row.height }
        // Lines go between rows that show something; read only when drawing, so setting them here is fine.
        val shown = rows.indices.filter { rows[it].height > 0 }
        lines = shown.drop(1).map { tops[it] }
        layout(constraints.maxWidth, tops.last()) {
            rows.forEachIndexed { i, row -> row.placeRelative(0, tops[i]) }
        }
    }
}

/** A row of a card in a lazy list, which can't hold the card itself: each row draws its slice of the
 *  frame, stretched past the row's cut edges and clipped to the row. */
@Composable
fun Modifier.settingsCardItem(first: Boolean, last: Boolean): Modifier {
    val frame = rememberFrame(MaterialTheme.colorScheme.surface)
    val w = frameWidth()
    val dashes = rememberDashes(w)
    val px = with(LocalDensity.current) { w.toDp() }
    val inset = with(LocalDensity.current) { 14.dp.toPx() }
    return fillMaxWidth()
        .padding(start = 16.dp, end = 16.dp, bottom = if(last) 12.dp else 0.dp)
        .drawBehind {
            val reach = 6 * w
            val top = if(first) 0 else -reach
            val bottom = size.height.roundToInt() + if(last) 0 else reach
            clipRect {
                drawIntoCanvas {
                    frame.setBounds(0, top, size.width.roundToInt(), bottom)
                    frame.draw(it.nativeCanvas)
                }
            }
            if(!first) dashedLine(dashes, w, 0f, 2 * w + inset, size.width - 3 * w - inset)
        }
        .padding(start = 2 * px, top = if(first) 2 * px else 0.dp, end = 3 * px, bottom = if(last) 3 * px else 0.dp)
}

/** A section header: a pink tag framed like the keys. */
@Composable
fun SectionTag(title: String) {
    Text(
        title,
        style = Typography.Body.Medium.copy(fontWeight = FontWeight.Bold),
        color = MaterialTheme.colorScheme.onPrimaryContainer,
        modifier = Modifier
            // As wide as its text, also where the parent stretches it (a full-width grid cell).
            .wrapContentWidth(Alignment.Start)
            .padding(start = 16.dp, top = 4.dp, bottom = 8.dp)
            .semantics { heading() }
            .framed(MaterialTheme.colorScheme.primaryContainer, horizontal = 10.dp, vertical = 3.dp)
    )
}

/** The bar with a sub-screen's title: cream, with the frames' outline under it. */
@Composable
internal fun Modifier.titleBar(): Modifier {
    val c = MaterialTheme.colorScheme
    val w = frameWidth()
    return fillMaxWidth()
        .padding(bottom = 12.dp)
        .background(c.surface)
        .drawBehind { drawRect(c.outline, Offset(0f, size.height - w), Size(size.width, w.toFloat())) }
}

/** A tip's or warning's box: a pink (or error-coloured) frame. */
@Composable
internal fun Modifier.tipFrame(warning: Boolean = false): Modifier = fillMaxWidth()
    .padding(horizontal = 16.dp, vertical = 8.dp)
    .framed(if(warning) MaterialTheme.colorScheme.errorContainer else MaterialTheme.colorScheme.primaryContainer)
