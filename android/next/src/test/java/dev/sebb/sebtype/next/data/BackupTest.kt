package dev.sebb.sebtype.next.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class BackupTest {
    @get:Rule val tmp = TemporaryFolder()

    private fun dir(name: String, vararg files: Pair<String, String>) = tmp.newFolder(name).apply {
        files.forEach { (n, text) -> File(this, n).apply { parentFile!!.mkdirs() }.writeText(text) }
    }

    private fun contents(dir: File) = dir.walkTopDown().filter { it.isFile }.associate { it.relativeTo(dir).invariantSeparatorsPath to it.readText() }

    /** A restore that fails at its second folder puts the first back as well: nothing of the backup stays. */
    @Test
    fun failurePartwayKeepsTheOriginals() {
        val mozc = dir("mozc", "user_history.db" to "phone's history")
        val rime = dir("rime", "rime_ice.userdb.txt" to "phone's words", "installation.yaml" to "phone's id", "sync/a.txt" to "a")
        val before = contents(mozc) to contents(rime)
        val swap = Backup.Swap(File(tmp.root, "originals"))
        swap.replace(dir("backup-mozc", "user_history.db" to "backup's history"), mozc)
        try {
            swap.replace(File(tmp.root, "unreadable"), rime, keep = setOf("installation.yaml"))
            throw AssertionError("the second step should fail")
        } catch (e: java.io.IOException) {
            swap.rollback()
        }
        assertEquals(before, contents(mozc) to contents(rime))
        assertFalse(File(tmp.root, "originals").exists())
    }

    /** A folder or file whose original can't be moved aside: what was moved goes back, the rest is never touched. */
    @Test
    fun originalsNeverMovedAsideStay() {
        val mozc = dir("mozc", "a.db" to "phone's a", "b.db" to "phone's b", "c.db" to "phone's c")
        val clipboard = File(tmp.root, "clipboard.json").apply { writeText("phone's clips") }
        val before = contents(mozc)
        val swap = Backup.Swap(File(tmp.root, "originals")) { from, to -> from.name != "b.db" && from.name != "clipboard.json" && from.renameTo(to) }
        for (step in listOf({ swap.replace(dir("backup-mozc", "a.db" to "backup's a"), mozc) },
            { swap.replaceFile(File(tmp.root, "backup-clipboard.json").apply { writeText("backup's clips") }, clipboard) })) {
            try {
                step()
                throw AssertionError("the step should fail")
            } catch (e: java.io.IOException) {
                swap.rollback()
            }
        }
        assertEquals(before, contents(mozc))
        assertEquals("phone's clips", clipboard.readText())
    }

    /** A rollback stopped by a failed move finishes at the next import, without clearing what it put back. */
    @Test
    fun rollbackThatFailsFinishesLater() {
        val mozc = dir("mozc", "a.db" to "phone's a", "b.db" to "phone's b", "c.db" to "phone's c")
        val clipboard = File(tmp.root, "clipboard.json").apply { writeText("phone's clips") }
        val before = contents(mozc)
        val originals = File(tmp.root, "originals")
        var failing = true
        val swap = Backup.Swap(originals) { from, to -> !(failing && to == File(mozc, "b.db")) && from.renameTo(to) }
        swap.replace(dir("backup-mozc", "a.db" to "backup's a", "d.db" to "backup's d"), mozc)
        swap.replaceFile(File(tmp.root, "backup-clipboard.json").apply { writeText("backup's clips") }, clipboard)
        try {
            swap.rollback()
            throw AssertionError("the rollback should stop at b.db")
        } catch (e: java.io.IOException) {
        }
        failing = false
        val next = Backup.Swap(originals)
        assertTrue(next.pending)
        next.rollback()
        assertEquals(before, contents(mozc))
        assertEquals("phone's clips", clipboard.readText())
        assertFalse(originals.exists())
    }

    @Test
    fun successReplacesAllButTheKeptAndDropsTheOriginals() {
        val rime = dir("rime", "rime_ice.userdb.txt" to "phone's words", "installation.yaml" to "phone's id")
        val clipboard = File(tmp.root, "clipboard.json").apply { writeText("phone's clips") }
        val swap = Backup.Swap(File(tmp.root, "originals"))
        swap.replace(dir("backup-rime", "rime_ice.userdb.txt" to "backup's words"), rime, keep = setOf("installation.yaml"))
        swap.replaceFile(File(tmp.root, "backup-clipboard.json").apply { writeText("backup's clips") }, clipboard)
        swap.commit()
        assertEquals(mapOf("rime_ice.userdb.txt" to "backup's words", "installation.yaml" to "phone's id"), contents(rime))
        assertEquals("backup's clips", clipboard.readText())
        assertFalse(File(tmp.root, "originals").exists())
    }
}
