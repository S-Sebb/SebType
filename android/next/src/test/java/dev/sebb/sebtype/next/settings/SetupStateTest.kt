package dev.sebb.sebtype.next.settings

import dev.sebb.sebtype.next.data.Prefs
import org.junit.Assert.assertEquals
import org.junit.Test

/** #285: who sees setup and its tips */
class SetupStateTest {
    @Test
    fun aNewUserGoesThroughTheTips() {
        assertEquals(Prefs.SETUP_TIPS_DUE, setupState(Prefs.SETUP_UNSEEN, on = false))
        // Turned on and chosen in setup, stopped on the tips: they come back
        assertEquals(Prefs.SETUP_TIPS_DUE, setupState(Prefs.SETUP_TIPS_DUE, on = true))
    }

    /** Done, then another keyboard chosen or SebType turned off: setup never comes back */
    @Test
    fun doneStaysDone() {
        assertEquals(Prefs.SETUP_DONE, setupState(Prefs.SETUP_DONE, on = true))
        assertEquals(Prefs.SETUP_DONE, setupState(Prefs.SETUP_DONE, on = false))
    }

    /** An update over an install that never saw setup, with SebType on but another keyboard in use */
    @Test
    fun anExistingUserNeverSeesSetup() {
        assertEquals(Prefs.SETUP_DONE, setupState(Prefs.SETUP_UNSEEN, on = true))
    }
}
