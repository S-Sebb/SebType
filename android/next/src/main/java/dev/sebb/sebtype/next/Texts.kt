package dev.sebb.sebtype.next

import android.content.Context
import android.content.res.Configuration
import android.content.res.Resources
import dev.sebb.sebtype.core.NativeCore
import java.util.Locale

/**
 * The words of the bar, the menus and the panels, in the keyboard's language as today's keyboard shows them
 * (所有操作项 in 中文), not the phone's.
 */
class Texts(private val base: Context) {
    private val byLanguage = HashMap<Int, Resources>()

    /** The keyboard's language: [NativeCore.ENGLISH], [NativeCore.CHINESE] or [NativeCore.JAPANESE] */
    var language = NativeCore.ENGLISH

    val res: Resources
        get() = byLanguage.getOrPut(language) {
            val locale = when (language) {
                NativeCore.CHINESE -> Locale.SIMPLIFIED_CHINESE
                NativeCore.JAPANESE -> Locale.JAPANESE
                else -> Locale.ENGLISH
            }
            base.createConfigurationContext(Configuration(base.resources.configuration).apply { setLocale(locale) }).resources
        }

    operator fun get(id: Int): String = res.getString(id)
}
