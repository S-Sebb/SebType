package dev.sebb.sebtype

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.junit.Test
import java.io.File
import java.io.IOException
import java.util.concurrent.CountDownLatch

class UpdatesTest {
    /** GitHub's latest release as its API answers, cut to what the check reads */
    private fun latest(tag: String, vararg assets: String, body: Any? = null): String {
        val o = JSONObject()
            .put("tag_name", tag)
            .put("html_url", "https://github.com/S-Sebb/SebType/releases/tag/$tag")
            .put("assets", JSONArray(assets.map {
                JSONObject().put("name", it).put("browser_download_url", "https://github.com/S-Sebb/SebType/releases/download/$tag/$it")
            }))
        if (body != null) o.put("body", body)
        return o.toString()
    }

    @Test
    fun newerReleaseOffersItsArm64Apk() {
        val json = latest("v0.2.0", "SebType-setup-0.2.0.exe", "SebType-0.2.0-arm64-v8a.apk", "sebtype-0.2.0-1.fc44.x86_64.rpm")
        assertEquals(
            Updates.Release("0.2.0", "https://github.com/S-Sebb/SebType/releases/download/v0.2.0/SebType-0.2.0-arm64-v8a.apk"),
            Updates.release(json, "0.1.0"),
        )
        assertNull("the same version", Updates.release(json, "0.2.0"))
        assertNull("an older one", Updates.release(json, "0.10.0"))
        assertNull("a release without the APK", Updates.release(latest("v0.2.0", "SebType-setup-0.2.0.exe"), "0.1.0"))
    }

    /** The releases before 0.1.0 were v0.1.30-sebtype.N: never newer than 0.1.0, though 0.1.30 > 0.1.0 */
    @Test
    fun oldSebtypeTagsAreNeverNewer() {
        assertNull(Updates.release(latest("v0.1.30-sebtype.412", "SebType-0.1.30-sebtype.412-arm64-v8a.apk"), "0.1.0"))
        for (tag in listOf("0.1.30-sebtype.412", "1.0.0-rc.1", "1.0.0+5", "01.2.3", "1.2", "v1.2.3.4", "latest")) {
            assertFalse(tag, Updates.newer(tag, "0.1.0"))
        }
    }

    @Test
    fun versionsCompareAsNumbers() {
        assertTrue(Updates.newer("0.1.10", "0.1.9"))
        assertTrue(Updates.newer("1.0.0", "0.99.99"))
        assertFalse(Updates.newer("0.1.9", "0.1.10"))
        // A build from before 0.1.0 reads as 0.1.30; a debug build named "dev" is offered nothing
        assertTrue(Updates.newer("0.2.0", "0.1.30-sebtype.412"))
        assertFalse(Updates.newer("0.1.0", "0.1.30-sebtype.412"))
        assertFalse(Updates.newer("9.9.9", "dev"))
    }

    /**
     * Turning the daily check's switch off stops its job mid-request: even when the request ignores the
     * interrupt and finishes, the check posts nothing.
     */
    @Test
    fun cancelledCheckPostsNothing() = runBlocking {
        val asking = CountDownLatch(1)
        val answer = CountDownLatch(1)
        val posted = mutableListOf<Updates.Release>()
        val check = launch(Dispatchers.IO) {
            Updates.fetchRelease({
                asking.countDown()
                while (true) try { answer.await(); break } catch (e: InterruptedException) {} // ignores the interrupt
                latest("v0.2.0", "SebType-0.2.0-arm64-v8a.apk")
            }, "0.1.0")?.let { posted += it }
        }
        asking.await()
        check.cancel()
        answer.countDown()
        check.join()
        assertTrue(posted.isEmpty())
        // Not cancelled, the same answer is a release to post
        assertEquals("0.2.0", Updates.fetchRelease({ latest("v0.2.0", "SebType-0.2.0-arm64-v8a.apk") }, "0.1.0")?.version)
    }

    private class FakeSession(val failWrite: Boolean) : Updates.InstallSession {
        val calls = mutableListOf<String>()
        override fun write(apk: File) {
            calls += "write"
            if (failWrite) throw IOException("No space left on device")
        }
        override fun commit() { calls += "commit" }
        override fun abandon() { calls += "abandon" }
        override fun close() { calls += "close" }
    }

    /** Storage full while the APK goes into the installer's session: the session is abandoned, not left behind. */
    @Test
    fun failedHandoffAbandonsTheSession() {
        val full = FakeSession(failWrite = true)
        assertTrue(runCatching { Updates.handOff(full, File("SebType.apk")) }.exceptionOrNull() is IOException)
        assertEquals(listOf("write", "abandon"), full.calls)
        val ok = FakeSession(failWrite = false)
        Updates.handOff(ok, File("SebType.apk"))
        assertEquals(listOf("write", "commit", "close"), ok.calls)
    }

    @Test
    fun releaseParsesBodyAndIgnoresBlankOrMissingBody() {
        val withBody = latest("v0.2.0", "SebType-0.2.0-arm64-v8a.apk", body = "\n  ### New\n- **Updates.** Checks daily.\n  ")
        assertEquals("### New\n- **Updates.** Checks daily.", Updates.release(withBody, "0.1.0")?.notes)

        val missing = latest("v0.2.0", "SebType-0.2.0-arm64-v8a.apk")
        assertNull(Updates.release(missing, "0.1.0")?.notes)

        val empty = latest("v0.2.0", "SebType-0.2.0-arm64-v8a.apk", body = "   \n\t  ")
        assertNull(Updates.release(empty, "0.1.0")?.notes)

        val jsonNull = latest("v0.2.0", "SebType-0.2.0-arm64-v8a.apk", body = JSONObject.NULL)
        assertNull(Updates.release(jsonNull, "0.1.0")?.notes)
    }

    @Test
    fun parseNotesHandlesHeadingsBulletsBoldAndEdgeCases() {
        val md = """
            ### New
            - **Automatic updates.** Checks GitHub once a day.
            - Plain bullet without bold.

            ### Improved
            - Faster **startup** and **prediction** on launch.

            ### Fixed
            - Keeps **unclosed bold as plain text.
            - Ignores **** empty markers.
            <b>Raw HTML</b> stays plain text.
        """.trimIndent()

        assertEquals(
            listOf(
                Updates.NoteLine.Heading("New"),
                Updates.NoteLine.Bullet(listOf(
                    Updates.NoteSpan("Automatic updates.", bold = true),
                    Updates.NoteSpan(" Checks GitHub once a day.", bold = false),
                )),
                Updates.NoteLine.Bullet(listOf(
                    Updates.NoteSpan("Plain bullet without bold.", bold = false),
                )),
                Updates.NoteLine.Heading("Improved"),
                Updates.NoteLine.Bullet(listOf(
                    Updates.NoteSpan("Faster ", bold = false),
                    Updates.NoteSpan("startup", bold = true),
                    Updates.NoteSpan(" and ", bold = false),
                    Updates.NoteSpan("prediction", bold = true),
                    Updates.NoteSpan(" on launch.", bold = false),
                )),
                Updates.NoteLine.Heading("Fixed"),
                Updates.NoteLine.Bullet(listOf(
                    Updates.NoteSpan("Keeps **unclosed bold as plain text.", bold = false),
                )),
                Updates.NoteLine.Bullet(listOf(
                    Updates.NoteSpan("Ignores **** empty markers.", bold = false),
                )),
                Updates.NoteLine.Text(listOf(
                    Updates.NoteSpan("<b>Raw HTML</b> stays plain text.", bold = false),
                )),
            ),
            Updates.parseNotes(md),
        )

        assertEquals(emptyList<Updates.NoteLine>(), Updates.parseNotes(null))
        assertEquals(emptyList<Updates.NoteLine>(), Updates.parseNotes("   \n  "))
    }
}
