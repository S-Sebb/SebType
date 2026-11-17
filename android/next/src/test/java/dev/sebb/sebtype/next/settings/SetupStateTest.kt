package dev.sebb.sebtype.next.settings

import androidx.datastore.preferences.core.PreferenceDataStoreFactory
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.PreferencesSerializer
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.emptyPreferences
import androidx.datastore.preferences.core.preferencesOf
import androidx.datastore.preferences.core.stringSetPreferencesKey
import dev.sebb.sebtype.next.data.Prefs
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** #285: what the settings open on. Android's keyboard settings aren't an input: SebType can be on before the app first opens. */
class SetupStateTest {
    @get:Rule val tmp = TemporaryFolder()
    /** Fresh data, whether or not SebType is on already: setup, and it stays due */
    @Test
    fun freshDataShowsSetup() {
        assertEquals(SetupRoute(Prefs.SETUP_TIPS_DUE, setup = true), setupRoute(null, todaysApp = false, atHome = true))
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
        assertEquals(SetupRoute(Prefs.SETUP_DONE, setup = false), setupRoute(null, todaysApp = true, atHome = true))
    }

    /** Today's app's languages from a backup imported before setup ran (the record says unseen): setup */
    @Test
    fun importedLanguagesAreNoUpdate() {
        assertEquals(SetupRoute(Prefs.SETUP_TIPS_DUE, setup = true), setupRoute(Prefs.SETUP_UNSEEN, todaysApp = true, atHome = true))
    }

    /** A screen left open (a restored back stack) stays, setup or not */
    @Test
    fun anOpenScreenStays() {
        assertEquals(SetupRoute(Prefs.SETUP_TIPS_DUE, setup = false), setupRoute(Prefs.SETUP_TIPS_DUE, todaysApp = false, atHome = false))
    }

    // Today's app's languages, globe order and layouts, other than its defaults
    private val subtypes = stringSetPreferencesKey("subtypes")
    private val languages = setOf("ja_JP:KeyboardLayoutSet=jis", "zh_CN:", "en_US:KeyboardLayoutSet=dvorak")

    private var stores = 0
    private fun store(vararg prefs: Preferences.Pair<*>) = PreferenceDataStoreFactory.create {
        tmp.newFile("settings${stores++}.preferences_pb").apply { delete() }
    }.also { store -> runBlocking { store.edit { it.putAll(*prefs) } } }

    private fun route(prefs: Preferences) = setupRoute(prefs[Prefs.SETUP.key], subtypes in prefs, atHome = true)

    /**
     * A set-up phone's backup, or today's app's, imported on a new phone keeps its languages and other options,
     * and setup still runs; the phone's export has the languages again, not setup's record.
     */
    @Test
    fun aBackupOnANewPhoneKeepsItsLanguagesAndSetup() = runBlocking {
        val phone = store()
        Prefs.import(phone, preferencesOf(Prefs.SETUP.key to Prefs.SETUP_DONE, subtypes to languages, Prefs.SOUND.key to true))
        val now = phone.data.first()
        assertEquals(languages, now[subtypes])
        assertEquals(true, now[Prefs.SOUND.key])
        assertEquals(SetupRoute(Prefs.SETUP_TIPS_DUE, setup = true), route(now))
        val exported = PreferencesSerializer.readFrom(okio.Buffer().write(Prefs.exported(phone)))
        assertEquals(preferencesOf(subtypes to languages, Prefs.SOUND.key to true), exported)
    }

    /** An older backup, or one without a record, on a set-up phone, or an update over today's app: still home */
    @Test
    fun aBackupOnASetUpPhoneKeepsHome() = runBlocking {
        for (backup in listOf(preferencesOf(Prefs.SETUP.key to Prefs.SETUP_TIPS_DUE), preferencesOf(subtypes to languages))) {
            for (phone in listOf(store(Prefs.SETUP.key to Prefs.SETUP_DONE), store(subtypes to setOf("en_US:")))) {
                Prefs.import(phone, backup)
                assertEquals(SetupRoute(Prefs.SETUP_DONE, setup = false), route(phone.data.first()))
            }
        }
    }

    /** A failed import puts the phone's file back as it was: its languages and setup's record */
    @Test
    fun aFailedImportRestoresTheRecordAndLanguages() = runBlocking {
        val phone = store(Prefs.SETUP.key to Prefs.SETUP_TIPS_DUE, subtypes to setOf("en_US:"))
        val before = phone.data.first() // as Backup.restore reads it first
        Prefs.import(phone, preferencesOf(subtypes to languages))
        assertFalse(phone.data.first() == before)
        Prefs.replace(phone, before) // Backup.restore's rollback
        assertEquals(before, phone.data.first())
    }
}
