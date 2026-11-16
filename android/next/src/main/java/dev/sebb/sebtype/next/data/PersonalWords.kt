package dev.sebb.sebtype.next.data

import android.content.ContentValues
import android.content.Context
import android.provider.UserDictionary
import android.util.Log
import dev.sebb.sebtype.core.NativeCore
import dev.sebb.sebtype.next.Engines
import org.json.JSONArray
import org.json.JSONObject
import org.mozc.android.inputmethod.japanese.protobuf.ProtoUserDictionaryStorage.UserDictionary.PosType
import org.mozc.android.inputmethod.japanese.protobuf.ProtoUserDictionaryStorage.UserDictionaryStorage
import org.mozc.android.inputmethod.japanese.protobuf.ProtoUserDictionaryStorage.UserDictionary as MozcDictionary
import java.io.File
import java.io.IOException

/**
 * A word of the personal dictionary: Android's user dictionary, as today's app keeps it. English words are
 * plain; a 日本語 word has the locale `ja` and its reading and Mozc part of speech in [shortcut]
 * ("よみ<TAB>number", the number of Mozc's `PosType`).
 */
data class PersonalWord(val word: String, val frequency: Int, val locale: String?, val appId: Int, val shortcut: String?) {
    val japanese get() = locale?.substringBefore('_') == "ja"
    val reading get() = shortcut?.substringBefore('\t').orEmpty()
    val pos: PosType get() = shortcut?.substringAfter('\t', "")?.toIntOrNull()?.let { PosType.forNumber(it) } ?: PosType.NOUN

    fun json(): JSONObject = JSONObject().put("word", word).put("frequency", frequency).put("locale", locale ?: JSONObject.NULL)
        .put("appId", appId).put("shortcut", shortcut ?: JSONObject.NULL)

    companion object {
        fun japanese(reading: String, word: String, pos: PosType) = PersonalWord(word, 250, "ja", 0, "$reading\t${pos.number}")

        /** The list format of today's app's backups and of the sync's `userdictionary.json` */
        fun list(text: String): List<PersonalWord> {
            val array = JSONArray(text)
            return (0 until array.length()).map { array.getJSONObject(it) }.map {
                PersonalWord(it.getString("word"), it.optInt("frequency", 250), it.optString("locale").takeIf { _ -> !it.isNull("locale") },
                    it.optInt("appId"), it.optString("shortcut").takeIf { _ -> !it.isNull("shortcut") })
            }
        }

        fun json(words: List<PersonalWord>) = JSONArray(words.map { it.json() }).toString()
    }
}

/** The personal dictionary (#14, #11), and 日本語's part of it in Mozc's user dictionary. */
object PersonalWords {
    private const val TAG = "SebType"

    fun all(context: Context): List<PersonalWord> {
        val out = ArrayList<PersonalWord>()
        context.contentResolver.query(UserDictionary.Words.CONTENT_URI,
            arrayOf(UserDictionary.Words.WORD, UserDictionary.Words.FREQUENCY, UserDictionary.Words.LOCALE,
                UserDictionary.Words.APP_ID, UserDictionary.Words.SHORTCUT), null, null, null)?.use { c ->
            while (c.moveToNext()) out += PersonalWord(c.getString(0), c.getInt(1), c.getString(2), c.getInt(3), c.getString(4))
        }
        return out
    }

    fun add(context: Context, words: List<PersonalWord>) {
        words.forEach { w ->
            context.contentResolver.insert(UserDictionary.Words.CONTENT_URI, ContentValues().apply {
                put(UserDictionary.Words.WORD, w.word)
                put(UserDictionary.Words.FREQUENCY, w.frequency)
                put(UserDictionary.Words.LOCALE, w.locale)
                put(UserDictionary.Words.APP_ID, w.appId)
                put(UserDictionary.Words.SHORTCUT, w.shortcut)
            })
        }
        if (words.any { it.japanese }) refreshMozc(context)
    }

    fun delete(context: Context, vararg words: PersonalWord) {
        val ids = ArrayList<Long>()
        for (word in words) context.contentResolver.query(UserDictionary.Words.CONTENT_URI,
            arrayOf(UserDictionary.Words._ID, UserDictionary.Words.LOCALE, UserDictionary.Words.SHORTCUT),
            "${UserDictionary.Words.WORD}=?", arrayOf(word.word), null)?.use { c ->
            while (c.moveToNext()) if (c.getString(1) == word.locale && c.getString(2) == word.shortcut) ids += c.getLong(0)
        }
        ids.forEach { context.contentResolver.delete(UserDictionary.Words.CONTENT_URI, "${UserDictionary.Words._ID}=$it", null) }
        if (words.any { it.japanese }) refreshMozc(context)
    }

    /** Mozc dictionaries the user imported (#11), each kept as the file it came as. */
    fun importedDir(context: Context) = File(context.filesDir, "ja-dictionaries")

    fun importJapanese(context: Context, name: String, bytes: ByteArray) {
        if (NativeCore.importMozcUserDictionary(bytes).isEmpty()) throw IOException("Mozc can't read $name")
        importedDir(context).apply { mkdirs() }.resolve(name.replace('/', '_')).writeBytes(bytes)
        refreshMozc(context)
    }

    /**
     * Writes Mozc's user dictionary from the 日本語 personal words and the imported files, on 日本語's thread, and
     * restarts Mozc so it reads it. [starting]: 日本語 is about to start, and words added elsewhere while it was
     * stopped (Android's settings, the sync) reach it; a running Mozc is left alone, and the file only written
     * when it changed.
     */
    fun refreshMozc(context: Context, starting: Boolean = false) {
        val app = context.applicationContext
        Engines.onThread(NativeCore.JAPANESE) {
            if (starting && NativeCore.running(NativeCore.JAPANESE)) return@onThread
            Engines.configure(app)
            val words = all(app).filter { it.japanese }
            val storage = UserDictionaryStorage.newBuilder()
            val own = words.joinToString("") { "${it.reading}\t${it.word}\t${MozcPos.name(it.pos)}\n" }
            val sources = listOf("SebType" to own.toByteArray()) +
                importedDir(app).listFiles().orEmpty().sortedBy { it.name }.map { it.name to it.readBytes() }
            sources.forEachIndexed { i, (name, bytes) ->
                if (bytes.isEmpty()) return@forEachIndexed
                val dictionary = NativeCore.importMozcUserDictionary(bytes)
                if (dictionary.isEmpty()) {
                    Log.w(TAG, "Mozc can't read a user dictionary")
                    return@forEachIndexed
                }
                storage.addDictionaries(MozcDictionary.parseFrom(dictionary).toBuilder().setId(i + 1L).setName(name))
            }
            val bytes = storage.build().toByteArray()
            val file = File(Engines.mozcDir(app), "user_dictionary.db")
            if (starting && file.isFile && file.readBytes().contentEquals(bytes)) return@onThread
            val tmp = File(file.path + ".new")
            tmp.apply { parentFile!!.mkdirs() }.writeBytes(bytes)
            if (!tmp.renameTo(file)) Log.w(TAG, "Can't write Mozc's user dictionary")
            // Mozc reads it as it starts: a running one stops, and starts again when 日本語 is next used.
            if (NativeCore.running(NativeCore.JAPANESE)) {
                NativeCore.save(NativeCore.JAPANESE)
                NativeCore.stop(NativeCore.JAPANESE)
            }
        }
    }
}

/** Mozc's names of its parts of speech, as its dictionary tool exports them (user_dictionary_storage.proto). */
object MozcPos {
    private val names = listOf(
        "品詞なし", "名詞", "短縮よみ", "サジェストのみ", "固有名詞", "人名", "姓", "名", "組織", "地名", "名詞サ変", "名詞形動", "数",
        "アルファベット", "記号", "顔文字", "副詞", "連体詞", "接続詞", "感動詞", "接頭語", "助数詞", "接尾一般", "接尾人名", "接尾地名",
        "動詞ワ行五段", "動詞カ行五段", "動詞サ行五段", "動詞タ行五段", "動詞ナ行五段", "動詞マ行五段", "動詞ラ行五段", "動詞ガ行五段",
        "動詞バ行五段", "動詞ハ行四段", "動詞一段", "動詞カ変", "動詞サ変", "動詞ザ変", "動詞ラ変", "形容詞", "終助詞", "句読点", "独立語",
    )

    fun name(pos: PosType) = names.getOrElse(pos.number) { names[1] }

    /** An unknown name (another IME's) is a noun, Mozc's default. */
    fun of(name: String): PosType = PosType.forNumber(names.indexOf(name).takeIf { it >= 0 } ?: 1) ?: PosType.NOUN
}
