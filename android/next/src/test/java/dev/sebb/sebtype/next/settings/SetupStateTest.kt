package dev.sebb.sebtype.next.settings

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
}
