package dev.sebb.sebtype.next.data

import dev.sebb.sebtype.next.Action
import dev.sebb.sebtype.next.Mode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import androidx.datastore.preferences.core.preferencesOf
import androidx.datastore.preferences.core.stringPreferencesKey
import org.junit.Test

/** Today's app's options, as its DataStore holds them (made-up values), in the new app's terms */
class MigrationTest {
    @Test
    fun actionBar() {
        // Today's ids; "more" and the cursor keys aren't the new bar's buttons.
        assertEquals(listOf(Action.EMOJI, Action.UNDO, Action.CLIPBOARD, Action.MODES, Action.LANGUAGE, Action.SELECT_ALL),
            Migration.actions("emoji,undo,clipboard_history,more,cursor_left,keyboard_modes,switch_language,select_all,paste"))
        assertEquals(emptyList<Action>(), Migration.actions(""))
    }

    // A 411 × 891 dp phone: today's keyboard is 250.9 dp high in portrait, its screen width's 61.05 %.
    private val portrait = Migration.todayHeights(411f, 891f).getValue("port")

    private val landscape = Migration.todayHeights(411f, 891f).getValue("land")

    private fun assertToday(height: Float, multiplier: Float, today: Migration.Today) {
        assertEquals(height, today.height, 0.1f)
        assertEquals(multiplier, today.multiplier, 0.001f)
    }

    @Test
    fun todaysHeight() {
        val phone = Migration.todayHeights(411f, 891f)
        assertToday(250.9f, 1f, phone.getValue("port"))
        assertToday(184.95f, 0.9f, phone.getValue("land")) // at least 45 % of the screen's height
        // A 10" tablet, not long: values-sw768dp in both orientations, whose minimum is 35 % of the width
        val tablet = Migration.todayHeights(800f, 1280f)
        assertToday(365.4f, 0.8f, tablet.getValue("port"))
        assertToday(448f, 0.9f, tablet.getValue("land"))
        // A long 7" one in landscape: values-sw600dp-long-land's 283.5 dp, within values-sw600dp's 46 %
        val long = Migration.todayHeights(610f, 1024f)
        assertToday(302.4f, 0.8f, long.getValue("port"))
        assertToday(280.6f, 0.9f, long.getValue("land"))
        // 0.8 only above 600 dp, as today's minDimDp > 600
        assertToday(302.4f, 1f, Migration.todayHeights(600f, 1024f).getValue("port"))
    }

    /** A tablet's portrait height before any change is 0.8 times its default: the new app's 1. */
    @Test
    fun unchangedOnATablet() {
        val today = Migration.todayHeights(800f, 1280f).getValue("port")
        assertEquals(1f, Migration.size("""{"currentMode":"Regular","heightMultiplier":0.8,"paddingDp":{"bottom":10.0}}""", false, today)!!.height, 0.001f)
    }

    /** Floating's own height is floatingHeightDp over 240 (before any change); the docked height stays Regular's. */
    @Test
    fun floatingHeight() {
        val floating = Migration.size("""{"currentMode":"Floating","heightMultiplier":1.0,"floatingWidthDp":360.0,"floatingHeightDp":288.0}""", false, portrait)!!
        assertEquals(Mode.FLOATING, floating.mode)
        assertEquals(1f, floating.height, 0.001f)
        assertEquals(1.25f, Migration.size("""{"currentMode":"Floating","heightMultiplier":1.25}""", false, portrait)!!.height, 0.001f)
        // Its own width and height, kept apart from the docked keyboard's (#283); today's defaults stay unset.
        assertEquals(1.2f, floating.floatingHeight!!, 0.001f)
        assertNull(floating.floatingWidth)
        val resized = Migration.size("""{"currentMode":"Regular","floatingWidthDp":280.5,"floatingHeightDp":240.0}""", false, portrait)!!
        assertEquals(280.5f, resized.floatingWidth!!, 0.001f)
        assertNull(resized.floatingHeight)
        // Today's limits, not the docked keyboard's 0.8–1.3: 96 dp is 0.4, a tall one stays tall.
        assertEquals(0.4f, Migration.size("""{"currentMode":"Floating","floatingHeightDp":60.0}""", false, portrait)!!.floatingHeight!!, 0.001f)
        assertEquals(2f, Migration.size("""{"currentMode":"Floating","floatingHeightDp":480.0}""", false, portrait)!!.floatingHeight!!, 0.001f)
    }

    @Test
    fun keyboardModeAndHeight() {
        val oneHanded = Migration.size("""{"currentMode":"OneHanded","heightMultiplier":1.4199999,"paddingDp":{"left":2.0,"top":4.0,"right":2.0,"bottom":10.0},"splitWidthFraction":0.8,"oneHandedRectDp":{"left":4.0,"top":4.0,"right":364.0,"bottom":30.0},"oneHandedDirection":"Left","floatingBottomOriginDp":{"first":0.0,"second":0.0},"floatingWidthDp":360.0,"floatingHeightDp":240.0}""", false, portrait)!!
        assertEquals(Mode.ONE_HANDED, oneHanded.mode)
        assertEquals(Mode.MAX_HEIGHT, oneHanded.height, 0.001f)
        assertEquals(true, oneHanded.left)
        // Landscape's 0.9, today's there before any change, is the new app's 1.
        val split = Migration.size("""{"currentMode":"Split","heightMultiplier":0.9,"oneHandedDirection":"Right"}""", true, landscape)!!
        assertEquals(Mode.SPLIT, split.mode)
        assertEquals(1f, split.height, 0.001f)
        assertEquals(false, split.left)
        assertEquals(Mode.STANDARD, Migration.size("""{"currentMode":"Regular","heightMultiplier":0.85}""", false, portrait)!!.mode)
        assertNull(Migration.size("", false, portrait))
    }

    /** Today's resize handle adds dp to the mode's height and leaves the multiplier at 1 (KeyboardResizers). */
    @Test
    fun heightAddedByResizing() {
        val regular = """{"currentMode":"Regular","heightMultiplier":1.0,"heightAdditionDp":48.2,"paddingDp":{"left":2.0,"top":4.0,"right":2.0,"bottom":10.0}}"""
        assertEquals(1.2f, Migration.size(regular, false, portrait)!!.height, 0.001f)
        val unchanged = """{"currentMode":"Regular","heightMultiplier":1.0,"paddingDp":{"left":2.0,"top":4.0,"right":2.0,"bottom":10.0}}"""
        assertEquals(1f, Migration.size(unchanged, false, portrait)!!.height, 0.001f)
        // Split's own addition, not Regular's
        val split = """{"currentMode":"Split","heightMultiplier":1.0,"heightAdditionDp":100.0,"splitHeightAdditionDp":-24.1,"splitPaddingDp":{"left":2.0,"top":4.0,"right":2.0,"bottom":10.0}}"""
        assertEquals(0.9f, Migration.size(split, false, portrait)!!.height, 0.001f)
    }

    /** What the new app already has wins over today's options, as after importing today's backup over it. */
    @Test
    fun keptWhereTheKeyboardHasThem() {
        val old = preferencesOf(
            stringPreferencesKey("favorite_actions_s") to "emoji,undo",
            stringPreferencesKey("last_used_emoji") to "😀<|>❤️",
            stringPreferencesKey("keyboard_settings_portrait") to """{"currentMode":"OneHanded","heightMultiplier":1.0,"oneHandedDirection":"Left"}""",
        )
        val moved = Migration.keyboardPrefs(old, setOf("actions", "mode_port", "one_handed_left_port"), mapOf("port" to portrait, "land" to landscape))
        assertEquals(mapOf("emoji_recent" to "😀\n❤️", "height_port" to 1f), moved)
        assertEquals(setOf("actions", "emoji_recent", "mode_port", "height_port", "one_handed_left_port"),
            Migration.keyboardPrefs(old, emptySet(), mapOf("port" to portrait, "land" to landscape)).keys)
    }

    @Test
    fun emojiRecents() {
        assertEquals(listOf("😀", "👍🏽", "❤️"), Migration.emoji("😀<|>👍🏽<|><|>❤️"))
    }
}
