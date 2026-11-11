package org.futo.inputmethod.latin.uix.theme

import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.drawable.Drawable
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

data class KeyBackground(
    val foregroundColor: Int?,
    val outlineColor: Int?,
    val outlineWidth: Dp = 3.dp,
    val padding: Rect = Rect(0,0,0,0),
    val gap: RectF = RectF(1.0f,1.0f,1.0f,1.0f),
    val background: Drawable
)

/** What Picnic sets beyond colours: the cloth, the key frames and the font. */
data class AdvancedThemeOptions(
    val backgroundImage: ImageBitmap? = null,
    val backgroundImageVisibleArea: Rect? = null,
    val actionBarOpacity: Float = 0.5f,
    val keyBorders: Boolean = false,
    val keyBackgrounds: KeyedBitmaps<KeyBackground>? = null,
    val font: Typeface? = null,
    /** Key popups (press preview and long-press menu); [font] when null. */
    val popupFont: Typeface? = null,
    /** Drawn behind the first candidate. */
    val candidateChip: Drawable? = null,
    val textSizeMultiplier: Float = 1.0f,
)
