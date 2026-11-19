package dev.sebb.sebtype

import android.content.Context

/** The latest release of SebType on GitHub; debug builds have a test hook instead (src/debug). */
@Suppress("UNUSED_PARAMETER")
internal fun updateSource(context: Context): String? = "https://api.github.com/repos/S-Sebb/SebType/releases/latest"
