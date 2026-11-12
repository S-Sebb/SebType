package org.futo.inputmethod.latin.uix

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import dev.sebb.sebtype.sync.PersonalDataImport

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

    // Personal data import (#11): made-up files in each format, told apart by their contents.
    private fun file(text: String) = text.byteInputStream()

    private val snapshot = "# Rime user dictionary\n#@/db_name\trime_ice\n#@/db_type\tuserdb\n#@/user_id\tx\n" +
        "ce shi \t测试\tc=3 d=1.2 t=40\n"
    private val wordList = "# made up\n---\nname: my_words\nversion: \"1\"\n...\n测试\tce shi\t100\n"
    private val mozc = "てすと\t手素都\t名詞\t\nてすとご\t手素都語\t名詞\tcomment\n"

    @Test
    fun rimeFilesAreRecognised() {
        assertEquals("rime_ice", PersonalDataImport.rimeLearnedWords(file(snapshot)))
        assertNull(PersonalDataImport.rimeLearnedWords(file(snapshot.replace("rime_ice", "luna_pinyin"))))
        assertEquals("my_words", PersonalDataImport.rimeWordList(file(wordList)))
        assertNull(PersonalDataImport.rimeWordList(file(wordList.replace("version: \"1\"\n", ""))))
    }

    @Test
    fun mozcExportIsRecognisedButNotOtherTabSeparatedFiles() {
        assertEquals("mozc", PersonalDataImport.mozcDictionary(file(mozc))?.kind)
        assertEquals(3, PersonalDataImport.mozcDictionary(file("\uFEFF" + mozc))?.offset)
        assertNull(PersonalDataImport.mozcDictionary(file(snapshot)))
        assertNull(PersonalDataImport.mozcDictionary(file(wordList)))
    }

    @Test
    fun futoPersonalDictionaryIsRead() {
        val json = """[{"word":"zorbleflux","frequency":250,"locale":"en_US","appId":0,"shortcut":null}]"""
        assertEquals(listOf(PersonalWord("zorbleflux", 250, "en_US", 0, null)), PersonalDataImport.personalWords(file(json)))
        assertNull(PersonalDataImport.personalWords(file(mozc)))
    }
}
