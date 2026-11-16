package dev.sebb.sebtype.next

import android.app.Application
import dev.sebb.sebtype.next.data.Migration
import dev.sebb.sebtype.next.data.Prefs
import dev.sebb.sebtype.next.sync.CrashReports
import dev.sebb.sebtype.next.sync.Sync

/** The keyboard's and the settings' process: crash reports, the update from today's app, the options and the sync. */
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        CrashReports.install(this)
        // Before anything reads the data it moves.
        Migration.run(this)
        Prefs.watch(this)
        Sync.start(this)
    }
}
