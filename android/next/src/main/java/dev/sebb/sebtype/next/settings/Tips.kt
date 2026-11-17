package dev.sebb.sebtype.next.settings

import android.graphics.Paint
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.InlineTextContent
import androidx.compose.foundation.text.appendInlineContent
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.Placeholder
import androidx.compose.ui.text.PlaceholderVerticalAlign
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.em
import dev.sebb.sebtype.next.Icons
import dev.sebb.sebtype.next.Icons.Icon
import dev.sebb.sebtype.next.Picnic
import dev.sebb.sebtype.next.PixelFrame
import dev.sebb.sebtype.next.R

/** The keys a tip is about, drawn as the keyboard draws them */
private enum class TipKey { GLOBE, SPACE, DELETE, KANA }

/**
 * The gestures that are hard to find (#285), one row each beside the key it is about: setup's last step
 * and About's Tips show the same card.
 */
@Composable
fun TipsCard() = Card {
    for ((key, text) in listOf(
        TipKey.GLOBE to R.string.tips_globe,
        TipKey.SPACE to R.string.tips_space,
        TipKey.DELETE to R.string.tips_delete,
        TipKey.KANA to R.string.tips_kana,
    )) Row(
        Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        KeyPicture(key)
        Spacer(Modifier.width(10.dp))
        TipText(stringResource(text))
    }
}

@Composable
fun TipsScreen(nav: Nav) = Screen(stringResource(R.string.settings_tips), nav::back) { TipsCard() }

/** The tip, with its 🌐 and ⌫ drawn as the keys' own icons, so it reads like the keyboard */
@Composable
private fun TipText(tip: String) {
    val icons = mapOf("🌐" to Icon.GLOBE, "⌫" to Icon.DELETE)
    val text = buildAnnotatedString {
        var rest = tip
        while (rest.isNotEmpty()) {
            val (at, symbol) = icons.keys.map { rest.indexOf(it) to it }.filter { it.first >= 0 }.minByOrNull { it.first }
                ?: (rest.length to "")
            append(rest.substring(0, at))
            if (symbol.isNotEmpty()) appendInlineContent(symbol, symbol)
            rest = rest.substring(at + symbol.length)
        }
    }
    val inline = icons.mapValues { (_, icon) ->
        InlineTextContent(Placeholder(1.1.em, 1.em, PlaceholderVerticalAlign.TextCenter)) {
            Canvas(Modifier.fillMaxSize()) { icon(icon, size.height * 1.05f) }
        }
    }
    Text(text, style = BodyText, color = Ink, inlineContent = inline)
}

private fun DrawScope.icon(icon: Icon, size: Float) =
    drawIntoCanvas { Icons.draw(it.nativeCanvas, icon, center.x, center.y, size, Picnic.INK) }

/** A key in its pixel frame, 44 × 40 dp at most, or 日本語's あ|ア chip as the bar draws it */
@Composable
private fun KeyPicture(key: TipKey) {
    val w = Picnic.pixel(LocalContext.current).toFloat()
    val kana = Paint(Paint.ANTI_ALIAS_FLAG).apply { textAlign = Paint.Align.CENTER }
    Canvas(Modifier.size(44.dp, 40.dp)) {
        val dp = density
        val cx = center.x
        drawIntoCanvas { c ->
            val canvas = c.nativeCanvas
            when (key) {
                TipKey.GLOBE, TipKey.DELETE -> {
                    PixelFrame.PINK.draw(canvas, cx - 16 * dp, 0f, cx + 16 * dp, size.height, w)
                    Icons.draw(canvas, if (key == TipKey.GLOBE) Icon.GLOBE else Icon.DELETE, cx, center.y - w / 2, 20 * dp, Picnic.INK)
                }
                TipKey.SPACE -> {
                    PixelFrame.CREAM.draw(canvas, 0f, 0f, size.width, size.height, w)
                    // A slide either way
                    val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Picnic.MUTED; strokeWidth = 1.6f * dp }
                    val y = center.y - w / 2
                    canvas.drawLine(cx - 13 * dp, y, cx + 13 * dp, y, paint)
                    for (s in listOf(-1, 1)) {
                        val tip = cx + s * 13 * dp
                        canvas.drawLine(tip, y, tip - s * 5 * dp, y - 5 * dp, paint)
                        canvas.drawLine(tip, y, tip - s * 5 * dp, y + 5 * dp, paint)
                    }
                }
                // CandidateBar's pill, あ in use on berry, scaled to the key's width
                TipKey.KANA -> {
                    val half = 8.5f * dp
                    val l = 0f
                    val r = size.width
                    val y = center.y
                    val fill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Picnic.CREAM }
                    canvas.drawRoundRect(l, y - half, r, y + half, half, half, fill)
                    fill.color = Picnic.BERRY
                    canvas.save()
                    canvas.clipRect(l, y - half, cx, y + half)
                    canvas.drawRoundRect(l, y - half, r, y + half, half, half, fill)
                    canvas.restore()
                    // The bar's own background shows its edge; on the card a line does
                    fill.color = Picnic.LINE
                    fill.style = Paint.Style.STROKE
                    fill.strokeWidth = dp
                    canvas.drawRoundRect(l + dp / 2, y - half, r - dp / 2, y + half, half, half, fill)
                    kana.textSize = 11 * dp
                    for ((i, k) in listOf("あ", "ア").withIndex()) {
                        kana.color = if (i == 0) Picnic.WHITE else Picnic.FADED
                        canvas.drawText(k, size.width / 4 * (1 + 2 * i), y + kana.textSize * 0.35f, kana)
                    }
                }
            }
        }
    }
}
