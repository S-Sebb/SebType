package dev.sebb.sebtype.next.settings

import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AddCircle
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.sebb.sebtype.next.R
import dev.sebb.sebtype.next.data.ChineseData
import dev.sebb.sebtype.next.data.ChineseWord
import dev.sebb.sebtype.next.data.PersonalWord
import dev.sebb.sebtype.next.data.PersonalWords
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.mozc.android.inputmethod.japanese.protobuf.ProtoUserDictionaryStorage.UserDictionary.PosType

// My words (#41, #14): each language's own words. English's and 日本語's are Android's personal dictionary,
// which the sync shares (日本語's also go into Mozc's user dictionary); 中文's are Rime's custom phrases.

@Composable
private fun AddRow(onClick: () -> Unit) = Card {
    Item(stringResource(R.string.settings_add), modifier = Modifier.clickable(onClick = onClick),
        icon = { Badge(false) { Icon(Icons.Outlined.AddCircle, null, tint = Ink) } })
}

@Composable
private fun NoWords() = Tip(stringResource(R.string.sebtype_settings_no_words))

/** A dialog of text fields, all needed; [save] gets their values. */
@Composable
private fun WordDialog(
    title: String,
    labels: List<String>,
    initial: List<String> = labels.map { "" },
    valid: (List<String>) -> Boolean = { v -> v.all { it.isNotBlank() } },
    onDelete: (() -> Unit)? = null,
    close: () -> Unit,
    save: (List<String>) -> Unit,
) {
    var values by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = close,
        title = { Text(title) },
        text = {
            Column {
                labels.forEachIndexed { i, label ->
                    OutlinedTextField(values[i], { v -> values = values.toMutableList().also { it[i] = v } }, singleLine = true,
                        label = { Text(label) }, modifier = Modifier.padding(top = if (i > 0) 8.dp else 0.dp))
                }
            }
        },
        confirmButton = {
            TextButton(enabled = valid(values), onClick = { save(values.map { it.trim() }); close() }) {
                Text(stringResource(R.string.sebtype_settings_save))
            }
        },
        dismissButton = {
            if (onDelete != null) TextButton(onClick = { onDelete(); close() }) { Text(stringResource(R.string.sebtype_settings_delete)) }
            else TextButton(onClick = close) { Text(stringResource(android.R.string.cancel)) }
        },
    )
}

/** The personal dictionary's words of one kind, read again after each change */
@Composable
private fun personalWords(changes: Int, japanese: Boolean): List<PersonalWord> {
    val context = LocalContext.current
    var words by remember { mutableStateOf(emptyList<PersonalWord>()) }
    LaunchedEffect(changes) {
        words = withContext(Dispatchers.IO) {
            PersonalWords.all(context).filter { it.japanese == japanese }.sortedBy { it.word.lowercase() }
        }
    }
    return words
}

@Composable
fun EnglishWordsScreen(nav: Nav) = Screen("English", nav::back) {
    val context = LocalContext.current
    var changes by remember { mutableIntStateOf(0) }
    var editing by remember { mutableStateOf<PersonalWord?>(null) }
    var adding by remember { mutableStateOf(false) }
    val words = personalWords(changes, japanese = false)
    AddRow { adding = true }
    if (words.isNotEmpty()) Card {
        words.forEach { w -> Item(w.word, modifier = Modifier.clickable { editing = w }) }
    }
    val label = listOf(stringResource(R.string.sebtype_settings_word))
    if (adding) WordDialog(stringResource(R.string.settings_add), label, close = { adding = false }) { (word) ->
        PersonalWords.add(context, listOf(PersonalWord(word, 250, null, 0, null)))
        changes++
    }
    editing?.let { old ->
        WordDialog(old.word, label, listOf(old.word), onDelete = { PersonalWords.delete(context, old); changes++ },
            close = { editing = null }) { (word) ->
            PersonalWords.delete(context, old)
            PersonalWords.add(context, listOf(old.copy(word = word)))
            changes++
        }
    }
}

@Composable
fun JapaneseWordsScreen(nav: Nav) = Screen("日本語", nav::back) {
    val context = LocalContext.current
    var changes by remember { mutableIntStateOf(0) }
    var editing by remember { mutableStateOf<PersonalWord?>(null) }
    var adding by remember { mutableStateOf(false) }
    val words = personalWords(changes, japanese = true)
    val import = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) context.startActivity(Intent(context, ImportActivity::class.java).setData(uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
    }
    SectionTag(stringResource(R.string.settings_file))
    Card {
        Item(stringResource(R.string.settings_import_file), modifier = Modifier.clickable { import.launch(arrayOf("text/*", "application/octet-stream")) },
            icon = { Badge(false) { Icon(Icons.Outlined.AddCircle, null, tint = Ink) } })
    }
    SectionTag(stringResource(R.string.settings_words))
    AddRow { adding = true }
    if (words.isNotEmpty()) Card {
        words.forEach { w -> Item(w.word, w.reading, Modifier.clickable { editing = w }) }
    }
    val labels = listOf(stringResource(R.string.settings_reading), stringResource(R.string.sebtype_settings_word))
    if (adding) WordDialog(stringResource(R.string.settings_add), labels, close = { adding = false }) { (reading, word) ->
        PersonalWords.add(context, listOf(PersonalWord.japanese(reading, word, PosType.NOUN)))
        changes++
    }
    editing?.let { old ->
        WordDialog(old.word, labels, listOf(old.reading, old.word), onDelete = { PersonalWords.delete(context, old); changes++ },
            close = { editing = null }) { (reading, word) ->
            PersonalWords.delete(context, old)
            PersonalWords.add(context, listOf(PersonalWord.japanese(reading, word, old.pos)))
            changes++
        }
    }
}

@Composable
fun ChineseWordsScreen(nav: Nav) = Screen(stringResource(R.string.sebtype_settings_my_words), nav::back) {
    val context = LocalContext.current
    var words by remember { mutableStateOf(ChineseData.myWords(context)) }
    var editing by remember { mutableStateOf<Int?>(null) }
    var adding by remember { mutableStateOf(false) }
    // On the words as they are when saved: a sync may have changed them since the screen read them (#272).
    fun change(edit: (List<ChineseWord>) -> List<ChineseWord>) {
        words = edit(words)
        ChineseData.setMyWords(context, edit(ChineseData.myWords(context)))
    }
    AddRow { adding = true }
    if (words.isEmpty()) NoWords() else Card {
        words.forEachIndexed { i, w -> Item(w.word, w.pinyin, Modifier.clickable { editing = i }) }
    }
    val labels = listOf(stringResource(R.string.sebtype_settings_word), stringResource(R.string.sebtype_settings_pinyin))
    val valid = { v: List<String> -> ChineseData.isValid(v[0].trim(), ChineseData.normalizePinyin(v[1])) }
    if (adding) WordDialog(stringResource(R.string.settings_add), labels, valid = valid, close = { adding = false }) { (word, pinyin) ->
        change { it + ChineseWord(word, ChineseData.normalizePinyin(pinyin)) }
    }
    editing?.let { i ->
        val old = words[i]
        WordDialog(old.word, labels, listOf(old.word, old.pinyin), valid, onDelete = { change { it - old } }, close = { editing = null }) { (word, pinyin) ->
            val new = ChineseWord(word, ChineseData.normalizePinyin(pinyin))
            change { list -> list.map { if (it == old) new else it } }
        }
    }
}
