package dev.sebb.sebtype.data

import android.content.Context
import dev.sebb.sebtype.core.NativeCore
import dev.sebb.sebtype.Engines

/** Settings › Privacy › Forget learned words (#41): one language's learned words go; the user's own words stay. */
object LearnedWords {
    /** [language] is "en", "zh" or "ja"; [done] runs on the main thread. */
    fun forget(context: Context, language: String, done: () -> Unit) {
        val app = context.applicationContext
        when (language) {
            // Through the engine, on the thread that types: a running English holds its words and saves them
            // back over files deleted under it.
            "en" -> NativeCore.post {
                Engines.configure(app)
                forget(NativeCore.ENGLISH)
                android.os.Handler(app.mainLooper).post(done)
            }
            "zh" -> ChineseData.forget(app) { done() }
            "ja" -> Engines.onThread(NativeCore.JAPANESE) {
                // Mozc forgets through itself, so it runs for this if it wasn't running.
                val running = NativeCore.running(NativeCore.JAPANESE)
                if (NativeCore.start(NativeCore.JAPANESE)) NativeCore.forget(NativeCore.JAPANESE)
                if (!running) NativeCore.stop(NativeCore.JAPANESE)
                android.os.Handler(app.mainLooper).post(done)
            }
        }
    }
}
