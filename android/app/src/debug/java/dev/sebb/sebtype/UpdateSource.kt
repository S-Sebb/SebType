package dev.sebb.sebtype

import android.content.Context
import java.io.File

/**
 * Debug builds check for updates only against a test release (android/test/update.sh): the URL in the app's
 * files/update-test-url, which `adb shell run-as` writes. Release builds ask GitHub (src/release).
 */
internal fun updateSource(context: Context): String? =
    File(context.filesDir, "update-test-url").takeIf { it.isFile }?.readText()?.trim()
