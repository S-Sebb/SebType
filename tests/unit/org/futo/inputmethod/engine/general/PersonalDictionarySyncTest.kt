package org.futo.inputmethod.engine.general

import org.futo.inputmethod.engine.general.PersonalDictionarySync.MOZC_FILE
import org.futo.inputmethod.engine.general.PersonalDictionarySync.WORDS_FILE
import org.futo.inputmethod.latin.uix.PersonalWord
import org.junit.Assert.assertEquals
import org.junit.Test

class PersonalDictionarySyncTest {
    private val japanese = PersonalWord("ピヨポン丸", 0, "ja", 0, "ぴよぽん\t1")
    private val english = PersonalWord("Quindlewump", 250, "en", 0, null)

    @Test
    fun anotherDevicesWordsArriveWithTheirLanguage() {
        val files = PersonalDictionarySync.snapshots(listOf(japanese, english))
        assertEquals("ぴよぽん\tピヨポン丸\t名詞\n", String(files.getValue(MOZC_FILE)))
        assertEquals(listOf(japanese), PersonalDictionarySync.newWords(MOZC_FILE, files.getValue(MOZC_FILE), null, listOf()))
        assertEquals(listOf(english), PersonalDictionarySync.newWords(WORDS_FILE, files.getValue(WORDS_FILE), null, listOf()))
    }

    @Test
    fun aWordDeletedHereDoesNotComeBack() {
        val old = "ぴよぽん\tピヨポン丸\t名詞\n".toByteArray()
        // A PC's Mozc export: its comment column, and a part of speech Mozc doesn't know, read as a noun.
        val new = "ぴよぽん\tピヨポン丸\t名詞\tPC\nぷるもに\tプルモニ語\t謎\n".toByteArray()
        assertEquals(listOf(PersonalWord("プルモニ語", 0, "ja", 0, "ぷるもに\t1")),
            PersonalDictionarySync.newWords(MOZC_FILE, new, old, listOf(english)))
    }
}
