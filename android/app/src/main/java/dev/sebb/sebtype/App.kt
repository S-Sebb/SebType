package dev.sebb.sebtype

import android.app.Application
import dev.sebb.sebtype.data.Migration
import dev.sebb.sebtype.data.Prefs
import dev.sebb.sebtype.sync.CrashReports
import dev.sebb.sebtype.sync.Sync

/** The keyboard's and the settings' process: crash reports, the update from today's app, the options, the sync and the update check. */
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        CrashReports.install(this)
        // Before anything reads the data it moves.
        Migration.run(this)
        Prefs.watch(this)
        Sync.start(this)
        Updates.start(this)
    }
}
