package dev.sebb.sebtype.settings

import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsBottomHeight
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
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
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.times
import dev.sebb.sebtype.Picnic
import dev.sebb.sebtype.PixelFrame
import kotlin.math.roundToInt

// The settings' look (#87, "C, pixel frames"), the keyboard's Picnic in light and dark mode alike (#111):
// rows sit in the keys' notched pixel frames on the checkered cloth, with pink tags as section headers.

private val Cloth = Color(Picnic.CLOTH)
val Cream = Color(Picnic.CREAM)
val Ink = Color(Picnic.INK)
val Muted = Color(Picnic.MUTED)
val Line = Color(Picnic.LINE)
val Pink = Color(Picnic.PINK)
val Berry = Color(Picnic.BERRY)
private val Outline = Color(Picnic.OUTLINE)

/** Material's parts (switches, dialogs, text fields) in Picnic's colours. */
private val Colours = lightColorScheme(
    primary = Berry, onPrimary = Color.White, primaryContainer = Pink, onPrimaryContainer = Ink,
    secondary = Berry, onSecondary = Color.White, secondaryContainer = Color(Picnic.BERRY_LOW), onSecondaryContainer = Color.White,
    background = Cloth, onBackground = Ink, surface = Cream, onSurface = Ink, onSurfaceVariant = Muted,
    surfaceContainerHighest = Color(Picnic.PINK_LOW), surfaceContainerHigh = Cream, surfaceContainer = Cream,
    outline = Outline, outlineVariant = Line, error = Color(Picnic.BERRY_LOW),
)

// Today's settings text (#267): no letter spacing, so text styles are given in full rather than taken from Material's.
/** A row's title */
val TitleText = TextStyle(fontSize = 20.sp, lineHeight = 30.sp)
/** A row's subtitle's colour: today's, the text's ink at 60 % */
val SubtitleInk = Ink.copy(alpha = 0.6f)
/** A row's subtitle */
val SubtitleText = TextStyle(fontSize = 14.sp, lineHeight = 20.sp)
/** A title bar's or a heading's text */
val HeadingText = TextStyle(fontSize = 20.sp, lineHeight = 20.sp, fontWeight = FontWeight.Medium)
/** Body text: tips, explanations */
val BodyText = TextStyle(fontSize = 16.sp, lineHeight = 24.sp)

@Composable
fun PicnicTheme(content: @Composable () -> Unit) = MaterialTheme(colorScheme = Colours, content = content)

/** Frames are as thick as the keys' frames, in whole pixels. */
@Composable
private fun frameWidth() = Picnic.pixel(LocalContext.current)

private val CardFrame = PixelFrame(Picnic.CREAM, Picnic.WHITE, Picnic.LINE)
private val TagFrame = PixelFrame(Picnic.PINK, Picnic.WHITE, Picnic.PINK_LOW)

/** Draws [frame] behind the content, which keeps clear of its outline, edges and shadow. */
@Composable
fun Modifier.framed(frame: PixelFrame = CardFrame, horizontal: Dp = 0.dp, vertical: Dp = 0.dp): Modifier {
    val w = frameWidth()
    val px = with(LocalDensity.current) { w.toDp() }
    return drawBehind {
        drawIntoCanvas { frame.draw(it.nativeCanvas, 0f, 0f, size.width, size.height, w.toFloat()) }
    }.padding(start = 2 * px + horizontal, top = 2 * px + vertical, end = 3 * px + horizontal, bottom = 3 * px + vertical)
}

/** The keyboard's cloth behind a whole screen */
@Composable
fun Modifier.cloth(): Modifier {
    val context = LocalContext.current
    val paint = remember { Picnic.cloth(context) }
    return drawBehind { drawIntoCanvas { it.nativeCanvas.drawRect(0f, 0f, size.width, size.height, paint) } }
}

/** The dashed line between a card's rows: one rect painted with a repeated dash and gap. */
@Composable
private fun rememberDashes(w: Int): ShaderBrush = remember(w) {
    val dash = (3 * w + 1) / 2
    val tile = Bitmap.createBitmap(2 * dash, w, Bitmap.Config.ARGB_8888)
    for (x in 0 until dash) for (y in 0 until w) tile.setPixel(x, y, Picnic.LINE)
    ShaderBrush(ImageShader(tile.asImageBitmap(), TileMode.Repeated, TileMode.Repeated))
}

private fun DrawScope.dashedLine(dashes: ShaderBrush, w: Int, y: Float, from: Float, to: Float) =
    drawRect(dashes, Offset(from, y), Size(to - from, w.toFloat()))

/** A framed card of rows, with a dashed line between rows that show something. */
@Composable
fun Card(modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val w = frameWidth()
    val dashes = rememberDashes(w)
    var lines by remember { mutableStateOf(emptyList<Int>()) }
    val inset = with(LocalDensity.current) { 14.dp.toPx() }
    Layout(
        content = content,
        modifier = modifier
            .fillMaxWidth()
            .padding(start = 16.dp, end = 16.dp, bottom = 12.dp)
            .framed()
            .drawBehind { for (y in lines) dashedLine(dashes, w, y.toFloat(), inset, size.width - inset) },
    ) { measurables, constraints ->
        val rows = measurables.map { it.measure(constraints.copy(minHeight = 0)) }
        val tops = rows.runningFold(0) { y, row -> y + row.height }
        lines = rows.indices.filter { rows[it].height > 0 }.drop(1).map { tops[it] }
        layout(constraints.maxWidth, tops.last()) { rows.forEachIndexed { i, row -> row.placeRelative(0, tops[i]) } }
    }
}

/** A section header: a pink tag framed like the keys. */
@Composable
fun SectionTag(title: String) = Text(
    title,
    style = TextStyle(fontSize = 16.sp, lineHeight = 16.sp, fontWeight = FontWeight.Bold), color = Ink,
    modifier = Modifier
        .wrapContentWidth(Alignment.Start)
        .padding(start = 16.dp, top = 4.dp, bottom = 8.dp)
        .semantics { heading() }
        .framed(TagFrame, horizontal = 10.dp, vertical = 3.dp),
)

/** A tip in a pink frame */
@Composable
fun Tip(text: String) = Text(
    text, style = BodyText, color = Ink,
    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).framed(TagFrame, 8.dp, 8.dp),
)

/**
 * A screen: on the cloth, scrolling, with a cream title bar and a back arrow when [title] is set, and
 * clear of the system bars.
 */
@Composable
fun Screen(title: String?, onBack: (() -> Unit)?, content: @Composable () -> Unit) {
    val w = frameWidth()
    Column(Modifier.fillMaxSize().cloth().windowInsetsPadding(WindowInsets.statusBars)) {
        if (title != null) Row(
            Modifier.fillMaxWidth().padding(bottom = 12.dp).background(Cream)
                .drawBehind { drawRect(Outline, Offset(0f, size.height - w), Size(size.width, w.toFloat())) },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // The arrow 16dp and the title 58dp from the edge, as today's
            if (onBack != null) {
                Spacer(Modifier.width(4.dp))
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, stringResource(android.R.string.cancel), tint = Ink)
                }
                Spacer(Modifier.width(6.dp))
            } else Spacer(Modifier.width(16.dp))
            Text(title, style = HeadingText, color = Ink,
                modifier = Modifier.padding(vertical = 16.dp).semantics { heading() })
        }
        Column(Modifier.fillMaxWidth().weight(1f).verticalScroll(rememberScrollState())) {
            content()
            Spacer(Modifier.windowInsetsBottomHeight(WindowInsets.navigationBars).height(16.dp))
        }
    }
}

/** One row of a card: an optional icon, a title and subtitle, and what sits at its end. */
@Composable
fun Item(
    title: String,
    subtitle: String? = null,
    modifier: Modifier = Modifier,
    icon: (@Composable () -> Unit)? = null,
    end: (@Composable () -> Unit)? = null,
) = Row(
    modifier.fillMaxWidth().heightIn(min = 68.dp)
        .padding(start = if (icon != null) 20.dp else 16.dp, end = 16.dp, top = 4.dp, bottom = 4.dp),
    verticalAlignment = Alignment.CenterVertically,
) {
    icon?.let {
        Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) { it() }
        Spacer(Modifier.width(12.dp))
    }
    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Text(title, style = TitleText, color = Ink, modifier = Modifier.heightIn(min = 24.dp))
        if (!subtitle.isNullOrEmpty()) Text(subtitle, style = SubtitleText, color = SubtitleInk)
    }
    Spacer(Modifier.width(4.dp))
    end?.invoke()
}

/** A row that opens a screen, with an arrow at its end */
@Composable
fun NavItem(title: String, subtitle: String? = null, icon: (@Composable () -> Unit)? = null, arrow: Boolean = true, onClick: () -> Unit) =
    Item(title, subtitle, Modifier.clickable(onClick = onClick), icon) {
        if (arrow) Icon(Icons.AutoMirrored.Filled.ArrowForward, null, tint = Ink)
    }

@Composable
fun SwitchItem(title: String, subtitle: String? = null, on: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) =
    Item(title, subtitle, Modifier.toggleable(on, enabled, Role.Switch, onChange)) {
        Switch(checked = on, onCheckedChange = null, enabled = enabled)
    }

@Composable
fun CheckItem(title: String, on: Boolean, onChange: (Boolean) -> Unit) =
    Item(title, null, Modifier.toggleable(on, true, Role.Checkbox, onChange)) {
        // In a switch-wide box, so its centre lines up with the switches'
        Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) { Checkbox(checked = on, onCheckedChange = null) }
    }

/** A home screen icon: a round badge, berry or pink */
@Composable
fun Badge(berry: Boolean, content: @Composable () -> Unit) = Box(
    Modifier.size(40.dp).background(if (berry) Color(Picnic.BERRY_LOW) else Pink, androidx.compose.foundation.shape.CircleShape),
    contentAlignment = Alignment.Center,
) { content() }

/** Languages' icon: a globe, as the 🌐 key's, in today's 26dp with a 20dp circle */
@Composable
fun Globe() = androidx.compose.foundation.Canvas(Modifier.size(26.dp)) {
    val u = size.width / 26
    val stroke = androidx.compose.ui.graphics.drawscope.Stroke(width = 2 * u)
    drawCircle(Ink, 10 * u, style = stroke)
    drawOval(Ink, Offset(9 * u, 3 * u), Size(8 * u, 20 * u), style = stroke)
    drawLine(Ink, Offset(3 * u, 13 * u), Offset(23 * u, 13 * u), stroke.width)
}

/** Keyboard's icon: two rows of five white keys and a space bar on the berry badge, as today's */
@Composable
fun KeyboardIcon() = androidx.compose.foundation.Canvas(Modifier.size(24.dp, 13.935.dp)) {
    val u = size.width / 62
    val corner = androidx.compose.ui.geometry.CornerRadius(2 * u, 2 * u)
    for (row in 0..1) for (col in 0..4)
        drawRoundRect(Color.White, Offset(col * 13.115f * u, row * 13.2f * u), Size(9.538f * u, 9.6f * u), corner)
    drawRoundRect(Color.White, Offset(10.731f * u, 26.4f * u), Size(40.538f * u, 9.6f * u), corner)
}

/** Picnic stays light in the system's dark mode (#111), so the system bars keep their dark icons. */
fun ComponentActivity.picnicEdgeToEdge() = enableEdgeToEdge(
    SystemBarStyle.light(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT),
    SystemBarStyle.light(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT),
)
