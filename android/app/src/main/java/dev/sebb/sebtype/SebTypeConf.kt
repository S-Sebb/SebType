package dev.sebb.sebtype

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.stringPreferencesKey
import dev.sebb.sebtype.core.NativeCore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.futo.inputmethod.engine.general.ChineseIME
import org.futo.inputmethod.engine.general.mozcUserProfileDir
import org.futo.inputmethod.latin.uix.getSetting
import org.futo.inputmethod.latin.uix.isDirectBootUnlocked
import java.io.File
import java.io.IOException

/**
 * The settings the phone shares with the PCs (#191): `sebtype.conf` in the files dir, the file core/ reads
 * (core::Settings). core/ applies them to 中文 and 日本語 itself; the settings screens read and write them here.
 * The first call also sets up the process's [NativeCore], so every use of it goes through [ensure] first.
 */
object SebTypeConf {
    private const val FILE = "sebtype.conf"

    enum class Option(val section: String, val key: String, val default: Boolean) {
        Traditional("Chinese", "Traditional", false),
        FullWidthPunctuation("Chinese", "FullWidthPunctuation", true),
        Emoji("Chinese", "Emoji", true),
        HalfWidthSpace("Japanese", "HalfWidthSpace", false),
    }

    private val conf = MutableStateFlow<String?>(null)
    /** The file's text, once read */
    val text: StateFlow<String?> = conf

    /** Sets up [NativeCore] with the settings, read once; until the phone is first unlocked, the defaults. */
    @Synchronized
    fun ensure(context: Context): String {
        conf.value?.let { return it }
        val app = context.applicationContext
        val unlocked = app.isDirectBootUnlocked
        val file = File(app.filesDir, FILE)
        val text = when {
            !unlocked -> ""
            file.isFile -> file.readText()
            else -> migrated(app)
        }
        NativeCore.configure(
            ChineseIME.getShared(app).apply { mkdirs() }.path,
            ChineseIME.getUser(app).apply { mkdirs() }.path,
            "", // librime logs to the system log only
            mozcUserProfileDir(app).path,
            text
        )
        // A core set up before the phone was unlocked has the defaults.
        NativeCore.setSettings(text)
        if(!unlocked) return text
        val normalized = NativeCore.settings()
        if(!file.isFile) write(file, normalized)
        conf.value = normalized
        return normalized
    }

    fun get(context: Context, option: Option): Boolean = value(ensure(context), option) ?: option.default

    @Synchronized
    fun set(context: Context, option: Option, on: Boolean) =
        replace(context, "${ensure(context)}[${option.section}]\n${option.key}=$on\n")

    /** Takes [text] as the whole file (a settings import); core/ keeps what it knows of it. */
    @Synchronized
    fun replace(context: Context, text: String) {
        ensure(context)
        NativeCore.setSettings(text)
        val normalized = NativeCore.settings()
        write(file(context), normalized)
        conf.value = normalized
    }

    fun file(context: Context) = File(context.applicationContext.filesDir, FILE)

    // The last line for a key wins, as in core::Settings::parse.
    private fun value(text: String, option: Option): Boolean? {
        var section = ""
        var found: Boolean? = null
        text.lineSequence().forEach { line ->
            if(line.startsWith("[") && line.endsWith("]")) section = line.substring(1, line.length - 1)
            else if(section == option.section && line.startsWith("${option.key}=")) found = line.substringAfter('=') == "true"
        }
        return found
    }

    private fun write(file: File, text: String) {
        val written = File(file.path + ".new")
        written.writeText(text)
        if(!written.renameTo(file)) throw IOException("Can't write ${file.path}")
    }

    /**
     * The settings as the app kept them before (FUTO's DataStore). 简/繁's "by language" is left unset: SebType's
     * Chinese has no region, so it was simplified, as Rime is by default.
     */
    fun migrated(context: Context) = buildString {
        val simplification = context.getSetting(stringPreferencesKey("ChineseIME_simplification"), "ByLanguage")
        append("[Chinese]\n")
        if(simplification != "ByLanguage") append("Traditional=${simplification == "Traditional"}\n")
        append("FullWidthPunctuation=${context.getSetting(booleanPreferencesKey("sebtype_zh_full_width_punctuation"), true)}\n")
        append("Emoji=${context.getSetting(booleanPreferencesKey("sebtype_zh_emoji"), true)}\n")
        append("[Japanese]\nHalfWidthSpace=${context.getSetting(booleanPreferencesKey("ime_ja_half_width_space"), false)}\n")
    }
}
