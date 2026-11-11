package org.futo.inputmethod.latin.uix.actions

import android.content.Context
import android.view.inputmethod.EditorInfo
import androidx.compose.runtime.mutableStateOf
import org.futo.inputmethod.latin.InputAttributes
import org.futo.inputmethod.latin.R
import org.futo.inputmethod.latin.settings.Settings
import org.futo.inputmethod.latin.uix.Action
import org.futo.inputmethod.latin.uix.PreferenceUtils

/**
 * SebType (#31): while incognito, English, 日本語 and 中文 learn nothing and suggest nothing learned, and the
 * clipboard history keeps no copies. Password, code and private (no personalised learning) fields are always
 * incognito; the manual toggle stays on, across restarts, until it is turned off.
 */
object Incognito {
    enum class Shown { Off, Field, Toggle }

    /** What the action bar's badge shows for the current field. */
    val shown = mutableStateOf(Shown.Off)

    fun toggledOn(context: Context) =
        PreferenceUtils.getDefaultSharedPreferences(context).getBoolean(Settings.PREF_SEBTYPE_INCOGNITO, false)

    private fun fieldNoLearning(context: Context, editorInfo: EditorInfo?) =
        InputAttributes(editorInfo, false, context.packageName).mNoLearning

    /** For a field that has just started: the settings still hold the previous field's attributes then. */
    fun inField(context: Context, editorInfo: EditorInfo?) =
        toggledOn(context) || fieldNoLearning(context, editorInfo)

    /**
     * For a copy (#139): judged by the field focused when it happens, which the keyboard may never have
     * shown in, so the settings may hold an older field. A focused view that is not a text field (a web
     * page in a private tab) counts as private when it asks for no personalised learning.
     */
    fun atCopy(context: Context, editorInfo: EditorInfo?) =
        inField(context, editorInfo) ||
            ((editorInfo?.imeOptions ?: 0) and EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING) != 0

    fun update(context: Context, editorInfo: EditorInfo?) {
        shown.value = when {
            toggledOn(context) -> Shown.Toggle
            fieldNoLearning(context, editorInfo) -> Shown.Field
            else -> Shown.Off
        }
    }
}

val IncognitoAction = Action(
    icon = R.drawable.incognito,
    name = R.string.sebtype_incognito,
    simplePressImpl = { manager, _ -> manager.setIncognito(!Incognito.toggledOn(manager.getContext())) },
    windowImpl = null,
)
