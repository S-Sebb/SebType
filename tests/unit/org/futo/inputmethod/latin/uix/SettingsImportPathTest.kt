package org.futo.inputmethod.latin.uix

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class SettingsImportPathTest {
    @get:Rule val tmp = TemporaryFolder()

    @Test
    fun entriesStayInsideTheirFolder() {
        val base = tmp.newFolder("files", "rime")
        assertEquals(File(base, "user/rime_ice.userdb/LOG").canonicalFile,
            SettingsExporter.resolveInside(base, "user/rime_ice.userdb/LOG"))
    }

    @Test
    fun entriesLeavingTheirFolderAreRejected() {
        val base = tmp.newFolder("files", "rime")
        assertNull(SettingsExporter.resolveInside(base, "../../shared_prefs/prefs.xml"))
        assertNull(SettingsExporter.resolveInside(base, "user/../../rime-evil/x"))
        assertNull(SettingsExporter.resolveInside(base, ".."))
    }
}
