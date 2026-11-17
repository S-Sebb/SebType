package dev.sebb.sebtype.next.settings

import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.preferencesOf
import androidx.datastore.preferences.core.stringSetPreferencesKey
import dev.sebb.sebtype.next.data.Prefs
import org.junit.Assert.assertEquals
import org.junit.Test

/** #285: what the settings open on. Android's keyboard settings aren't an input: SebType can be on before the app first opens. */
class SetupStateTest {
    /** Fresh data, whether or not SebType is on already: setup, and it stays due */
    @Test
    fun freshDataShowsSetup() {
        assertEquals(SetupRoute(Prefs.SETUP_TIPS_DUE, setup = true), setupRoute(Prefs.SETUP_UNSEEN, todaysApp = false, atHome = true))
        // Stopped on the tips: they come back
        assertEquals(SetupRoute(Prefs.SETUP_TIPS_DUE, setup = true), setupRoute(Prefs.SETUP_TIPS_DUE, todaysApp = false, atHome = true))
    }

    /** Done, then another keyboard chosen or SebType turned off: home */
    @Test
    fun doneStaysDone() {
        assertEquals(SetupRoute(Prefs.SETUP_DONE, setup = false), setupRoute(Prefs.SETUP_DONE, todaysApp = false, atHome = true))
    }

    /** An update over today's app opens on home and records setup as done */
    @Test
    fun todaysAppsUsersNeverSeeSetup() {
        assertEquals(SetupRoute(Prefs.SETUP_DONE, setup = false), setupRoute(Prefs.SETUP_UNSEEN, todaysApp = true, atHome = true))
    }

    /** A screen left open (a restored back stack) stays, setup or not */
    @Test
    fun anOpenScreenStays() {
        assertEquals(SetupRoute(Prefs.SETUP_TIPS_DUE, setup = false), setupRoute(Prefs.SETUP_TIPS_DUE, todaysApp = false, atHome = false))
    }

    private val todaysSubtypes = stringSetPreferencesKey("subtypes")

    private fun route(prefs: Preferences) =
        setupRoute(prefs[Prefs.SETUP.key] ?: Prefs.SETUP_UNSEEN, todaysSubtypes in prefs, atHome = true)

    /** A set-up phone's backup, or today's app's, imported on a new phone: setup still runs there */
    @Test
    fun aSetUpPhonesBackupKeepsSetup() {
        val backup = preferencesOf(Prefs.SETUP.key to Prefs.SETUP_DONE, todaysSubtypes to setOf("en_US:"), Prefs.SOUND.key to true)
        val phone = Prefs.imported(backup, emptyPreferences())
        assertEquals(SetupRoute(Prefs.SETUP_TIPS_DUE, setup = true), route(phone))
        assertEquals(true, phone[Prefs.SOUND.key])
    }

    /** An older backup, from before setup was done or before setup's record, on a set-up phone: still home */
    @Test
    fun anOlderBackupKeepsHome() {
        val phone = preferencesOf(Prefs.SETUP.key to Prefs.SETUP_DONE)
        for (backup in listOf(preferencesOf(Prefs.SETUP.key to Prefs.SETUP_TIPS_DUE), emptyPreferences())) {
            assertEquals(SetupRoute(Prefs.SETUP_DONE, setup = false), route(Prefs.imported(backup, phone)))
        }
        // An update over today's app keeps its evidence whatever the backup has
        val updated = preferencesOf(todaysSubtypes to setOf("en_US:"))
        assertEquals(SetupRoute(Prefs.SETUP_DONE, setup = false), route(Prefs.imported(emptyPreferences(), updated)))
    }

    /** A backup has neither setup's record nor its evidence */
    @Test
    fun exportLeavesSetupOut() {
        val prefs = preferencesOf(Prefs.SETUP.key to Prefs.SETUP_DONE, todaysSubtypes to setOf("en_US:"), Prefs.SOUND.key to true)
        assertEquals(preferencesOf(Prefs.SOUND.key to true), Prefs.exported(prefs))
    }
}
