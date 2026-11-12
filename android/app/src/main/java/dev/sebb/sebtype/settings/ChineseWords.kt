package dev.sebb.sebtype.settings

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import dev.sebb.sebtype.chinese.ChineseMyWords
import dev.sebb.sebtype.chinese.ChineseWord
import org.futo.inputmethod.latin.R
import org.futo.inputmethod.latin.uix.settings.BottomSpacer
import org.futo.inputmethod.latin.uix.settings.NavigationItem
import org.futo.inputmethod.latin.uix.settings.NavigationItemStyle
import org.futo.inputmethod.latin.uix.settings.ScreenTitle
import dev.sebb.sebtype.settings.SettingsCard
import org.futo.inputmethod.latin.uix.settings.Tip
import dev.sebb.sebtype.settings.settingsCardItem

/** Chinese "My words" (#41): words with the pinyin that types them, kept in rime-ice's custom_phrase. */
@Composable
fun ChineseWordsScreen(navController: NavHostController) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var words by remember { mutableStateOf<List<ChineseWord>?>(null) }
    // null: closed; a word with an empty word: adding; otherwise editing that word
    var editing by remember { mutableStateOf<ChineseWord?>(null) }

    LaunchedEffect(Unit) { words = withContext(Dispatchers.IO) { ChineseMyWords.read(context) } }

    fun save(newWords: List<ChineseWord>) {
        words = newWords
        scope.launch { ChineseMyWords.write(context, newWords) }
    }

    // Lazy, with each word drawing its slice of the card, so long lists open and scroll smoothly (#87).
    LazyColumn {
        item { ScreenTitle(stringResource(R.string.sebtype_settings_my_words), showBack = true, navController) }
        item {
            SettingsCard {
                NavigationItem(
                    title = stringResource(R.string.user_dict_settings_add_menu_title),
                    style = NavigationItemStyle.HomePrimary,
                    navigate = { editing = ChineseWord("", "") },
                    icon = painterResource(R.drawable.plus_circle)
                )
            }
        }
        val list = words ?: return@LazyColumn
        if(list.isEmpty()) item { Tip(stringResource(R.string.sebtype_settings_no_words)) }
        itemsIndexed(list) { i, word ->
            Box(Modifier.settingsCardItem(first = i == 0, last = i == list.lastIndex)) {
                NavigationItem(
                    title = word.word,
                    subtitle = word.pinyin,
                    style = NavigationItemStyle.MiscNoArrow,
                    navigate = { editing = word }
                )
            }
        }
        item { BottomSpacer() }
    }

    editing?.let { original ->
        ChineseWordDialog(
            original = original,
            onDismiss = { editing = null },
            onSave = { new ->
                val list = words.orEmpty()
                save(if(original.word.isEmpty()) list + new else list.map { if(it == original) new else it })
                editing = null
            },
            onDelete = if(original.word.isEmpty()) null else {{
                save(words.orEmpty() - original)
                editing = null
            }}
        )
    }
}

@Composable
private fun ChineseWordDialog(
    original: ChineseWord,
    onDismiss: () -> Unit,
    onSave: (ChineseWord) -> Unit,
    onDelete: (() -> Unit)?
) {
    var word by remember { mutableStateOf(original.word) }
    var pinyin by remember { mutableStateOf(original.pinyin) }
    val code = ChineseMyWords.normalizePinyin(pinyin)
    val pinyinInvalid = pinyin.isNotEmpty() && pinyin.any { it.isLetterOrDigit() && it.lowercaseChar() !in 'a'..'z' }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.sebtype_settings_my_words)) },
        text = {
            Column {
                OutlinedTextField(
                    value = word, onValueChange = { word = it.trim() }, singleLine = true,
                    label = { Text(stringResource(R.string.sebtype_settings_word)) }
                )
                OutlinedTextField(
                    value = pinyin, onValueChange = { pinyin = it }, singleLine = true,
                    label = { Text(stringResource(R.string.sebtype_settings_pinyin)) },
                    isError = pinyinInvalid,
                    supportingText = if(pinyinInvalid) {{ Text(stringResource(R.string.sebtype_settings_pinyin_invalid)) }} else null,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Ascii),
                    modifier = Modifier.padding(top = 8.dp)
                )
            }
        },
        confirmButton = {
            TextButton(
                enabled = !pinyinInvalid && ChineseMyWords.isValid(word, code),
                onClick = { onSave(ChineseWord(word, code)) }
            ) { Text(stringResource(R.string.sebtype_settings_save)) }
        },
        dismissButton = {
            if(onDelete != null) TextButton(onClick = onDelete) { Text(stringResource(R.string.sebtype_settings_delete)) }
            else TextButton(onClick = onDismiss) { Text(stringResource(android.R.string.cancel)) }
        }
    )
}
