package dev.sebb.sebtype

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * SebType's key layouts, in JSON files in assets/layouts/ (one per page). A page is rows of keys, ten
 * key-widths across. A key is a string (the character it types and shows) or an object:
 *
 *  - `text`: what it types; `label`: what it shows, when that differs (中文's `，` types `,` so Rime makes
 *    it full- or half-width);
 *  - `code`: a key that does something else (shift, delete, symbols, symbols2, digits, letters, globe, space,
 *    enter);
 *  - `pink`: a text key drawn like the function keys (the punctuation beside the space bar);
 *  - `width` in key-widths (1 by default); `gap`: empty space of that width, no key;
 *  - `hint`: the small character in its corner; `more`: what a long press offers, the first one picked
 *    unless the finger moves;
 *  - `currency`: the language's currency sign ($, or ¥ in 中文 and 日本語) instead of a fixed text;
 *  - `en`, `zh`, `ja`: what differs in that language, over the rest (the punctuation keys).
 *
 * The three languages share one letters page, so their keys are in the same places by construction (#10).
 * A row may set `height` in rows (the number row is 0.9 of one).
 */
class Layout(val name: String, val rows: List<Row>) {
    class Row(val keys: List<Key>, val height: Float)

    enum class Code { TEXT, GAP, SHIFT, DELETE, SYMBOLS, SYMBOLS2, DIGITS, LETTERS, GLOBE, SPACE, ENTER }

    class Key(
        val code: Code,
        val text: String,
        val label: String,
        val width: Float,
        val hint: String?,
        val more: List<Key>,
        val currency: Boolean,
        val pink: Boolean = false,
    ) {
        /** Shift, delete and the page and language keys: pink. Enter: berry. Letters, space: cream. */
        val function get() = code != Code.TEXT && code != Code.SPACE && code != Code.ENTER
    }

    companion object {
        private val cache = HashMap<Pair<String, String>, Layout>()

        /** The page [name] as [lang] (en, zh or ja) has it. */
        fun load(context: Context, name: String, lang: String): Layout = cache.getOrPut(name to lang) {
            parse(name, context.assets.open("layouts/$name.json").bufferedReader().use { it.readText() }, lang)
        }

        fun parse(name: String, json: String, lang: String): Layout {
            val rows = JSONObject(json).getJSONArray("rows")
            return Layout(name, (0 until rows.length()).map { i ->
                val row = rows.get(i)
                if (row is JSONArray) Row(keys(row, lang), 1f)
                else (row as JSONObject).let { Row(keys(it.getJSONArray("keys"), lang), it.optDouble("height", 1.0).toFloat()) }
            })
        }

        private fun keys(array: JSONArray, lang: String) = (0 until array.length()).map { key(array.get(it), lang) }

        private fun key(json: Any, lang: String): Key {
            if (json is String) return Key(Code.TEXT, json, json, 1f, null, emptyList(), false)
            val o = JSONObject((json as JSONObject).toString())
            o.optJSONObject(lang)?.let { over -> over.keys().forEach { o.put(it, over.get(it)) } }
            if (o.has("gap")) return Key(Code.GAP, "", "", o.getDouble("gap").toFloat(), null, emptyList(), false)
            val code = if (o.has("code")) Code.valueOf(o.getString("code").uppercase()) else Code.TEXT
            val text = o.optString("text", if (code == Code.SPACE) " " else "")
            return Key(
                code,
                text,
                o.optString("label", text),
                o.optDouble("width", 1.0).toFloat(),
                o.optString("hint").ifEmpty { null },
                o.optJSONArray("more")?.let { keys(it, lang) } ?: emptyList(),
                o.optBoolean("currency"),
                o.optBoolean("pink"),
            )
        }
    }
}
