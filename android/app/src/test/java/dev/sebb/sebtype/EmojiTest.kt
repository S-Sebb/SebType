package dev.sebb.sebtype

import org.junit.Assert.assertEquals
import org.junit.Test

class EmojiTest {
    private fun item(text: String, name: String, vararg keywords: String) =
        Emoji.Item(text, arrayOf(name, name, name), emptyList(), keywords.toList(), face = false)

    /** Today's order: a name or keyword that is the search, then one that starts with it, then one containing it; any language. */
    @Test
    fun searchRanksAsToday() {
        val cat = item("🐈", "cat", "pet")
        val catFace = item("🐱", "cat face", "cat")
        val scatter = item("🫨", "shaking face", "scatter")
        val heart = Emoji.Item("❤️", arrayOf("red heart", "红心", "赤いハート"), emptyList(), listOf("爱"), face = false)
        val all = listOf(scatter, catFace, cat, heart)
        assertEquals(listOf(catFace, cat, scatter), Emoji.search(all, "Cat"))
        assertEquals(listOf(heart), Emoji.search(all, "红心"))
        assertEquals(listOf(heart), Emoji.search(all, "爱"))
        assertEquals(emptyList<Emoji.Item>(), Emoji.search(all, "dog"))
    }
}
