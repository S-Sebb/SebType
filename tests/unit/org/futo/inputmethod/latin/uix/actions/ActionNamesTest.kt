package org.futo.inputmethod.latin.uix.actions

import org.junit.Assert.assertEquals
import org.junit.Test
import java.io.File

/** Every action a layout or key text names exists: an unknown one makes the whole layout fail to load (#182). */
class ActionNamesTest {
    @Test
    fun layoutsAndKeyTextsNameOnlyRegisteredActions() {
        val sources = File("java/assets/layouts").walk().filter { it.extension == "yaml" } +
            File("java/src/org/futo/inputmethod/keyboard/internal/KeyboardTextsTable.java")
        val unknown = sources.flatMap { file ->
            Regex("""(?:code|icon)/action_(\w+)""").findAll(file.readText())
                .map { it.groupValues[1] }.filter { it !in AllActionKeys }.map { "${file.name}: $it" }
        }.toSortedSet()
        assertEquals(emptySet<String>(), unknown)
    }
}
