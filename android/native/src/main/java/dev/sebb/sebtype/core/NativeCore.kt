package dev.sebb.sebtype.core

/**
 * The phone's way into SebType's core (core/ in the repository, the PCs' engine code): one process-wide
 * Core with 中文 (librime) and 日本語 (Mozc in this process), in libsebtype.so (sebtype_jni.cpp). Calls are
 * synchronous and take one lock, so the keyboard and the background setup can both call it.
 */
object NativeCore {
    init { System.loadLibrary("sebtype") }

    const val ENGLISH = 0
    const val CHINESE = 1
    const val JAPANESE = 2

    // core/'s Field and Keys
    const val FIELD_TEXT = 0
    const val FIELD_PLAIN = 1
    const val FIELD_NUMBER = 2
    const val FIELD_PHONE = 3
    const val FIELD_PASSWORD = 4
    const val KEYS_KANA = 0
    const val KEYS_LETTERS = 1
    const val KEYS_SYMBOLS = 2

    /** Once per process; [conf] is sebtype.conf's text. Later calls only change the paths. */
    @JvmStatic external fun configure(rimeShared: String, rimeUser: String, rimeLog: String, mozcProfile: String, conf: String)
    /** The schema each new 中文 session selects; a change restarts 中文. */
    @JvmStatic external fun setRimeSchema(schema: String)
    /** Mozc's profile and dictionary (a region of [file]; length 0: all of it); a change restarts 日本語. */
    @JvmStatic external fun setMozcData(profile: String, file: String, offset: Long, length: Long)
    @JvmStatic external fun setSettings(conf: String)
    @JvmStatic external fun settings(): String

    @JvmStatic external fun selectLanguage(lang: Int)
    @JvmStatic external fun setField(field: Int, learning: Boolean)
    @JvmStatic external fun setKeys(keys: Int, landscape: Boolean)

    /** A key as an X11 keysym (a character's: [charSym]); [NativeState.taken] says whether the engine took it. */
    @JvmStatic external fun key(sym: Int, mods: Int): NativeState
    /** Clears the composition and types [text]'s letters. */
    @JvmStatic external fun type(text: String): NativeState
    @JvmStatic external fun selectCandidate(index: Int): NativeState
    /** Moves the cursor inside the preedit to [position] characters from its start. */
    @JvmStatic external fun moveCursor(position: Int): NativeState
    @JvmStatic external fun undo(): NativeState
    /** Commits what is typed. */
    @JvmStatic external fun flush(): NativeState
    /** Drops what is typed. */
    @JvmStatic external fun clear(): NativeState
    @JvmStatic external fun state(): NativeState
    /** 简 ⇄ 繁, あ ⇄ ア */
    @JvmStatic external fun setAlternate(on: Boolean)

    /** Starts a language's engine if it isn't running; false if it can't. */
    @JvmStatic external fun start(lang: Int): Boolean
    @JvmStatic external fun running(lang: Int): Boolean
    /** Deploying or saving in the engine's own thread. */
    @JvmStatic external fun busy(lang: Int): Boolean
    @JvmStatic external fun stop(lang: Int)
    @JvmStatic external fun deploy(lang: Int)
    @JvmStatic external fun save(lang: Int)
    /** Forgets what the engine learned itself (Mozc's history). */
    @JvmStatic external fun forget(lang: Int)

    /** A user dictionary file in a format Mozc imports, as a serialized UserDictionary. */
    @JvmStatic external fun importMozcUserDictionary(text: ByteArray): ByteArray

    /** X11's keysym for a character: Latin-1 as it is, the rest as Unicode keysyms. */
    @JvmStatic fun charSym(codePoint: Int) = if(codePoint < 0x100) codePoint else 0x1000000 + codePoint

    const val XK_BackSpace = 0xff08
    const val XK_Tab = 0xff09
    const val XK_Return = 0xff0d
    const val XK_Left = 0xff51
    const val XK_Right = 0xff53
}

/** What is typed after a call (sebtype_jni.cpp's state()). Positions are in UTF-16 units, as Android's. */
class NativeState(
    @JvmField val taken: Boolean,
    /** Text to commit */
    @JvmField val commit: String,
    /** Text to delete around the cursor before the commit, in characters (Mozc's) */
    @JvmField val deleteBefore: Int,
    @JvmField val deleteAfter: Int,
    /** Where the cursor goes after the commit: 0 after it, -n n characters back */
    @JvmField val commitCursor: Int,
    @JvmField val segments: Array<String>,
    @JvmField val highlighted: BooleanArray,
    /** In the preedit; -1 for none */
    @JvmField val cursor: Int,
    @JvmField val candidates: Array<String>,
    @JvmField val comments: Array<String>,
    /** The highlighted candidate, -1 for none */
    @JvmField val selected: Int,
) {
    val preedit: String get() = segments.joinToString("")
}
