package org.futo.inputmethod.updates

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.datastore.preferences.core.booleanPreferencesKey
import org.futo.inputmethod.latin.BuildConfig
import org.futo.inputmethod.latin.uix.SettingsKey

fun Context.openURI(uri: String, newTask: Boolean = false) {
    try {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(uri))
        if (newTask) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        startActivity(intent)
    } catch(e: ActivityNotFoundException) {
        Toast.makeText(this, e.localizedMessage, Toast.LENGTH_SHORT).show()
    }
}

val dismissedMigrateUpdateNotice = SettingsKey(
    key = booleanPreferencesKey("dismissedMigrateFdroidObtainiumNotice"),
    default = BuildConfig.IS_PLAYSTORE_BUILD
)
