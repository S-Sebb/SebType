package dev.sebb.sebtype

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.drawable.Icon
import android.os.Build
import android.util.Size
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.InlineSuggestion
import android.view.inputmethod.InlineSuggestionsRequest
import android.widget.HorizontalScrollView
import android.widget.LinearLayout
import android.widget.inline.InlinePresentationSpec
import androidx.annotation.RequiresApi
import androidx.autofill.inline.UiVersions
import androidx.autofill.inline.common.TextViewStyle
import androidx.autofill.inline.common.ViewStyle
import androidx.autofill.inline.v1.InlineSuggestionUi

/**
 * Inline autofill (#53 B9): a password manager's suggestions (logins, cards) as chips over the bar, through
 * Android's inline suggestions (Android 11 and later). A tap on one fills the field; the app's autofill
 * service does that, the keyboard only shows them.
 */
@SuppressLint("ViewConstructor")
class AutofillStrip(context: Context) : HorizontalScrollView(context) {
    private val density = resources.displayMetrics.density
    private val row = LinearLayout(context).apply { orientation = LinearLayout.HORIZONTAL }
    private val chips = Chips<View>()

    init {
        isHorizontalScrollBarEnabled = false
        addView(row, LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }

    val showing get() = row.childCount > 0

    /** What the request asks the service's chips to look like: the bar's height, the Picnic chip */
    @RequiresApi(Build.VERSION_CODES.R)
    fun request(barHeight: Int): InlineSuggestionsRequest {
        val chip = ViewStyle.Builder()
            .setBackground(Icon.createWithResource(context, R.drawable.autofill_chip))
            .setPadding(px(12), 0, px(12), 0)
            .setLayoutMargin(px(4), px(6), px(4), px(6))
            .build()
        val style = UiVersions.newStylesBuilder().addStyle(
            InlineSuggestionUi.newStyleBuilder()
                .setChipStyle(chip)
                .setTitleStyle(TextViewStyle.Builder().setTextColor(Picnic.INK).setTextSize(16f).build())
                .setSubtitleStyle(TextViewStyle.Builder().setTextColor(Picnic.MUTED).setTextSize(13f).build())
                .build()
        ).build()
        val spec = InlinePresentationSpec.Builder(Size(px(60), barHeight), Size(resources.displayMetrics.widthPixels, barHeight))
            .setStyle(style).build()
        return InlineSuggestionsRequest.Builder(listOf(spec)).setMaxSuggestionCount(MAX).build()
    }

    /** The service's answer: its chips, in order; none clears the strip. [changed] runs as chips arrive. */
    @RequiresApi(Build.VERSION_CODES.R)
    fun show(suggestions: List<InlineSuggestion>, barHeight: Int, changed: () -> Unit) {
        row.removeAllViews()
        val answer = chips.start(suggestions.size)
        suggestions.forEachIndexed { i, s ->
            s.inflate(context, Size(ViewGroup.LayoutParams.WRAP_CONTENT, barHeight), context.mainExecutor) { view ->
                val shown = chips.inflated(answer, i, view ?: return@inflate) ?: return@inflate
                row.removeAllViews()
                shown.forEach { row.addView(it) }
                changed()
            }
        }
        changed()
    }

    /** The field is left: chips still inflating for it never show. */
    fun clear() {
        chips.start(0)
        row.removeAllViews()
    }

    private fun px(dp: Int) = (dp * density).toInt()

    private companion object {
        const val MAX = 6
    }
}

/**
 * The chips of the service's latest answer as they inflate, in its order. The inflations finish later, on
 * their own: one from an earlier answer, or from a field since left (#283), adds nothing.
 */
class Chips<T : Any> {
    private var answer = 0
    private var slots = arrayOfNulls<Any>(0)

    /** A new answer of [count] chips; the number its inflations bring back */
    fun start(count: Int): Int {
        slots = arrayOfNulls(count)
        return ++answer
    }

    /** Chip [index] of [answer] inflated: the chips to show now, or null when that answer is over */
    @Suppress("UNCHECKED_CAST")
    fun inflated(answer: Int, index: Int, chip: T): List<T>? {
        if (answer != this.answer) return null
        slots[index] = chip
        return slots.filterNotNull() as List<T>
    }
}
