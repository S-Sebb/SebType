package org.futo.inputmethod.latin.uix.actions

import android.util.Log
import org.futo.inputmethod.latin.BuildConfig

val IsDebug = BuildConfig.DEBUG

/** Crashes a debug build; a release build logs the error and carries on. */
fun throwIfDebug(ex: Exception) {
    if(IsDebug) throw ex
    Log.e(ex.javaClass.simpleName, "Unexpected error", ex)
}
