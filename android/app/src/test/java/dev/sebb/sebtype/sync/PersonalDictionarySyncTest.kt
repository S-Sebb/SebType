package dev.sebb.sebtype.sync

import dev.sebb.sebtype.core.ChineseWordSync
import dev.sebb.sebtype.core.MozcWordSync
import org.futo.inputmethod.latin.uix.PersonalWord
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.attribute.BasicFileAttributes

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

    /** One device's 中文 My words (#272), as (pinyin, word); null before they were first saved. */
    private inner class ChineseDevice(var words: List<Pair<String, String>>?) {
        val own = tmp.newFile().apply { delete() }
        var copy: ByteArray? = null

        fun file(now: Long) = MozcWordSync.format(ChineseWordSync.ownEntries(own, words, now).values)

        fun takeIn(other: ByteArray) {
            val changes = ChineseWordSync.changes(own, words, other, copy)
            changes.words?.let { words = it }
            changes.save()
            copy = other
        }
    }

    @Test
    fun chineseWordsAddDeleteAndComeBack() {
        val a = ChineseDevice(listOf("pumoli" to "噗莫里"))
        val b = ChineseDevice(null)
        assertEquals("never saved: none to tell", "", String(b.file(1)))
        b.takeIn(a.file(1))
        a.takeIn(b.file(2))
        assertEquals(listOf("pumoli" to "噗莫里"), b.words)

        a.words = listOf()
        b.takeIn(a.file(10))
        assertEquals("deleted on a, so on b", listOf<Pair<String, String>>(), b.words)
        a.takeIn(b.file(11))
        assertEquals(listOf<Pair<String, String>>(), a.words)

        b.words = listOf("pumoli" to "噗莫里")
        a.takeIn(b.file(20))
        assertEquals("added again on b", listOf("pumoli" to "噗莫里"), a.words)
        // The PC's format (sync-server/test_sebtype_sync.py reads it the same).
        assertEquals("pumoli\t噗莫里\t名詞\t\t20\n", String(b.file(30)))
    }

    @Test
    fun chineseOldClientCopiesGoBeforeTheFirstSync() {
        // Copies of two devices' files a client before #272 kept; a first sync takes in one, then is cut off.
        val sync = tmp.newFolder()
        val copies = listOf("dev-a", "dev-b").map { File(sync, "$it/${ChineseWordSync.FILE}").apply { parentFile!!.mkdirs(); writeText("x") } }
        val own = File(tmp.newFolder(), ChineseWordSync.FILE)
        ChineseWordSync.dropOldCopies(own, sync)
        assertFalse(copies.any { it.exists() })
        ChineseWordSync.ownEntries(own, listOf())
        copies[0].writeText("taken in")
        ChineseWordSync.dropOldCopies(own, sync)
        assertTrue("once its own file is there, its copies are what it took in", copies[0].exists())
    }

    @Test
    fun myWordsAreReplacedWholeNotWrittenInPlace() {
        val file = tmp.newFile().apply { writeText("old") }
        val key = { Files.readAttributes(file.toPath(), BasicFileAttributes::class.java).fileKey() }
        val before = key()
        ChineseWordSync.replace(file, "new".toByteArray())
        assertEquals("new", file.readText())
        assertNotEquals("a new file renamed over it", before, key())
        File(file.path + ".tmp").mkdirs() // the new file can't be written
        assertThrows(IOException::class.java) { ChineseWordSync.replace(file, "newer".toByteArray()) }
        assertEquals("new", file.readText())
    }

    @Test
    fun chineseClockAhead() {
        val phone = ChineseDevice(listOf())
        phone.takeIn("pumoli\t噗莫里\t名詞\t\t5000\n".toByteArray()) // from a device whose clock ran ahead
        assertEquals(listOf("pumoli" to "噗莫里"), phone.words)
        phone.words = listOf()
        val deleted = ChineseWordSync.ownEntries(phone.own, phone.words, 100).values.single()
        assertEquals(5001L, deleted.time)
        assertTrue(deleted.deleted)
        val unchanged = ChineseWordSync.changes(phone.own, phone.words, "pumoli\t噗莫里\t名詞\t\t5000\n".toByteArray(), null)
        assertNull("stays deleted", unchanged.words)
    }
}
