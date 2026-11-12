package org.futo.inputmethod.latin.uix.settings.pages

import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.tooling.preview.Preview
import androidx.navigation.NavHostController
import androidx.navigation.compose.rememberNavController
import org.futo.inputmethod.latin.R
import org.futo.inputmethod.latin.uix.actions.ActionsEditor
import org.futo.inputmethod.latin.uix.settings.ScreenTitle

@Preview(showBackground = true)
@Composable
fun ActionEditorScreen(navController: NavHostController = rememberNavController()) {
    Column {
        ScreenTitle(stringResource(R.string.action_editor_title), showBack = true, navController)
        ActionsEditor { }
    }
}