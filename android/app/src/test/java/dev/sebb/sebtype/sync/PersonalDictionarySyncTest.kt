package dev.sebb.sebtype.sync

import dev.sebb.sebtype.core.MozcWordSync
import org.futo.inputmethod.latin.uix.PersonalWord
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class PersonalDictionarySyncTest {
    @get:Rule val tmp = TemporaryFolder()

    private val japanese = PersonalWord("ピヨポン丸", 0, "ja", 0, "ぴよぽん\t1")
    private val english = PersonalWord("Quindlewump", 250, "en", 0, null)

    /** One device: its own file, its words, and what it takes in from another's file. */
    private inner class Phone(var words: List<PersonalWord>) {
        val own = tmp.newFile().apply { delete() }
        var copy: ByteArray? = null

        fun file(now: Long) = MozcWordSync.format(PersonalDictionarySync.ownMozc(own, words, now).values)

        fun takeIn(other: ByteArray) {
            val changes = PersonalDictionarySync.japaneseChanges(own, words, other, copy)
            words = words - changes.removed.toSet() + changes.added
            changes.save()
            copy = other
        }
    }

    @Test
    fun anotherDevicesWordsArriveWithTheirLanguage() {
        val phone = Phone(listOf(japanese, english))
        val mozc = phone.file(5)
        assertEquals("ぴよぽん\tピヨポン丸\t名詞\n", String(mozc)) // a first sync dates nothing
        assertEquals(listOf(japanese), Phone(listOf()).apply { takeIn(mozc) }.words)
        val words = PersonalDictionarySync.wordsFile(phone.words)
        assertEquals(listOf(english), PersonalDictionarySync.newWords(words, null, listOf()))
    }

    @Test
    fun aWordDeletedHereDoesNotComeBackFromAnOldClient() {
        val phone = Phone(listOf(english))
        phone.copy = "ぴよぽん\tピヨポン丸\t名詞\n".toByteArray()
        phone.file(5)
        // An old client's file (a PC's Mozc export: its comment column, and a part of speech Mozc doesn't know,
        // read as a noun) that still has the word deleted here, and gained another.
        phone.takeIn("ぴよぽん\tピヨポン丸\t名詞\tPC\nぷるもに\tプルモニ語\t謎\n".toByteArray())
        assertEquals(listOf(english, PersonalWord("プルモニ語", 0, "ja", 0, "ぷるもに\t1")), phone.words)
    }

    @Test
    fun deletionsSyncAndAWordCanComeBack() {
        val a = Phone(listOf(japanese))
        val b = Phone(listOf())
        b.takeIn(a.file(1))
        a.takeIn(b.file(2))
        assertEquals(listOf(japanese), b.words)

        a.words = listOf()
        b.takeIn(a.file(10))
        assertEquals("deleted on a, so on b", listOf<PersonalWord>(), b.words)
        a.takeIn(b.file(11))
        assertEquals(listOf<PersonalWord>(), a.words)

        val again = PersonalWord("ピヨポン丸", 0, "ja", 0, "ぴよぽん\t5") // added again on b, as a person's name
        b.words = listOf(again)
        a.takeIn(b.file(20))
        assertEquals(listOf(again), a.words)
    }

    @Test
    fun theNewestChangeWinsInEitherOrder() {
        val start = PersonalDictionarySync.ownMozc(tmp.newFile().apply { delete() }, listOf(japanese), 1)
        val bytes = MozcWordSync.format(start.values)
        val deleted = MozcWordSync.stamp(start, listOf(), 20)
        val edited = MozcWordSync.stamp(start, listOf(MozcWordSync.Entry("ぴよぽん", "ピヨポン丸", "人名")), 30)
        for ((own, other) in listOf(deleted to edited, edited to deleted)) {
            val mine = own.toMutableMap()
            MozcWordSync.merge(mine, MozcWordSync.format(other.values), bytes)
            assertEquals(MozcWordSync.Entry("ぴよぽん", "ピヨポン丸", "人名", "", 30), mine.values.single())
        }
    }

    @Test
    fun aSyncCutOffBeforeTheWordsAreSavedLosesNothing() {
        val a = Phone(listOf(japanese))
        val b = Phone(listOf())
        b.file(1)
        val file = a.file(1)
        PersonalDictionarySync.japaneseChanges(b.own, b.words, file, null) // the process ends before the words are saved
        assertEquals("nothing deleted on b", "", String(b.file(2)))
        b.takeIn(file)
        assertEquals(listOf(japanese), b.words)
    }

    @Test
    fun aChangeAfterOneDatedInTheFutureWins() {
        val ahead = mapOf(("ぴぴ" to "ピピ") to MozcWordSync.Entry("ぴぴ", "ピピ", "名詞", time = 1000))
        assertEquals(1001L, MozcWordSync.stamp(ahead, listOf(), 50).values.single().time)
        assertEquals(1001L, MozcWordSync.stamp(ahead, listOf(MozcWordSync.Entry("ぴぴ", "ピピ", "人名")), 50).values.single().time)
        assertEquals(ahead, MozcWordSync.stamp(ahead, listOf(MozcWordSync.Entry("ぴぴ", "ピピ", "名詞")), 50))
    }

    @Test
    fun theFileIsThePcsFormat() {
        // The same words as sync-server/test_sebtype_sync.py's test_old_clients writes.
        val own = mapOf(
            ("ぴぴ" to "ピピ丸") to MozcWordSync.Entry("ぴぴ", "ピピ丸", "名詞"),
            ("もふ" to "モフ") to MozcWordSync.Entry("もふ", "モフ", "名詞"),
        )
        val file = MozcWordSync.format(MozcWordSync.stamp(own, listOf(MozcWordSync.Entry("ぴぴ", "ピピ丸", "人名", "made up")), 1234).values)
        assertEquals("#-\tもふ\tモフ\t\t\t1234\nぴぴ\tピピ丸\t人名\tmade up\t1234\n", String(file))
        assertEquals(file.toList(), MozcWordSync.format(MozcWordSync.parse(file).values).toList())
    }
}
