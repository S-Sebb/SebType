package icu.astronot233.rime

import android.content.res.AssetManager
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.time.LocalDate
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Deploys rime-ice (packed into this test APK's assets by smoke-test.sh) through the
 * public Kotlin API, then types through Rime the way FUTO's ChineseIME does.
 */
@RunWith(AndroidJUnit4::class)
class RimeIceSmokeTest {

    companion object {
        private const val TAG = "RimeIceSmokeTest"

        @BeforeClass @JvmStatic
        fun deployRimeIce() {
            val context = InstrumentationRegistry.getInstrumentation().context
            val root = File(context.filesDir, "rime").apply { deleteRecursively() }
            val shared = File(root, "shared")
            val user = File(root, "user").apply { mkdirs() }
            copyAssets(context.assets, "rime-ice", shared)

            RimeApi.initialize(shared.path, user.path, "sebtype-smoke")
            assertTrue("startup", RimeApi.startup(true))
            // Deployment runs in the background; sessions open only once it is done.
            val started = System.currentTimeMillis()
            while (!RimeApi.selectSchema("rime_ice")) {
                check(System.currentTimeMillis() - started < 15 * 60_000) { "rime_ice never became selectable" }
                Thread.sleep(1000)
            }
            Log.i(TAG, "deployed in ${System.currentTimeMillis() - started} ms")
        }

        private fun copyAssets(assets: AssetManager, path: String, dest: File) {
            val children = assets.list(path).orEmpty()
            if (children.isEmpty()) {
                dest.parentFile!!.mkdirs()
                assets.open(path).use { input -> dest.outputStream().use { input.copyTo(it) } }
            } else {
                children.forEach { copyAssets(assets, "$path/$it", File(dest, it)) }
            }
        }
    }

    private fun candidatesFor(input: String): List<String> {
        RimeApi.clearComposition()
        assertTrue("simulate $input", RimeApi.simulateKeySequence(input))
        val texts = RimeApi.getCandidates().map { it.text }
        Log.i(TAG, "$input -> ${texts.take(5)}")
        RimeApi.clearComposition()
        return texts
    }

    // Plain abbreviated pinyin (no Lua involved).
    @Test fun ranhGivesRanhou() = assertEquals("然后", candidatesFor("ranh").firstOrNull())

    // lua_translator@*date_translator
    @Test fun rqGivesTodaysDate() {
        val today = LocalDate.now().toString()
        val candidates = candidatesFor("rq")
        assertTrue("$today in $candidates", today in candidates)
    }

    // lua_filter@*pin_cand_filter
    @Test fun hmIsPinnedToHoumian() = assertEquals("后面", candidatesFor("hm").firstOrNull())
}
