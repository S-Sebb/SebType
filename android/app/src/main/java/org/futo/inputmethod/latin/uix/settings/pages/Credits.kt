package org.futo.inputmethod.latin.uix.settings.pages

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.navigation.NavHostController
import androidx.navigation.compose.rememberNavController
import org.futo.inputmethod.latin.R
import org.futo.inputmethod.latin.uix.settings.BottomSpacer
import org.futo.inputmethod.latin.uix.settings.NavigationItem
import org.futo.inputmethod.latin.uix.settings.NavigationItemStyle
import org.futo.inputmethod.latin.uix.settings.Route
import dev.sebb.sebtype.settings.SettingsCard
import org.futo.inputmethod.latin.uix.settings.ScreenTitle
import org.futo.inputmethod.latin.uix.settings.ScrollableList
import org.futo.inputmethod.latin.uix.settings.UserSettingsMenu
import org.futo.inputmethod.latin.uix.settings.pages.credits.ThirdPartyItem
import org.futo.inputmethod.latin.uix.settings.pages.credits.ThirdPartyList
import org.futo.inputmethod.latin.uix.settings.pages.credits.codeContribs
import org.futo.inputmethod.latin.uix.settings.pages.credits.languageContribs
import org.futo.inputmethod.latin.uix.settings.pages.credits.layoutContribs
import org.futo.inputmethod.latin.uix.settings.pages.credits.text
import org.futo.inputmethod.latin.uix.settings.render
import org.futo.inputmethod.latin.uix.settings.userSettingNavigationItem
import org.futo.inputmethod.latin.uix.theme.Typography
import org.futo.inputmethod.updates.openURI
import dev.sebb.sebtype.settings.SettingsCard

@Composable
@Preview(showBackground = true)
fun ProjectInfoView(
    projectIndex: Int = 1,
    navController: NavHostController = rememberNavController()
) {
    val context = LocalContext.current
    val info = ThirdPartyList[projectIndex]
    ScrollableList {
        ScreenTitle(
            stringResource(R.string.credits_menu_project_information_title, info.name),
            showBack = true, navController
        )

        Text(
            info.description,
            modifier = Modifier.fillMaxWidth().padding(8.dp),
            style = Typography.Body.Regular,
            textAlign = TextAlign.Center
        )

        SettingsCard {
            NavigationItem(
                title = stringResource(R.string.credits_menu_project_url_link),
                subtitle = info.projectUrl,
                style = NavigationItemStyle.ExternalLink,
                navigate = {
                    context.openURI(info.projectUrl)
                }
            )
        }

        SettingsCard {
            Text(
                info.copyright,
                modifier = Modifier.padding(12.dp),
                style = Typography.Small
            )
            Text(
                info.license.text(context),
                modifier = Modifier.padding(12.dp),
                style = Typography.Small
            )
        }
        BottomSpacer()
    }
}

@Composable
fun <T> VerticalGrid(
    modifier: Modifier = Modifier,
    items: List<T>,
    columns: Int,
    reverseLayout: Boolean = false,
    verticalArrangement: Arrangement.Vertical = if (!reverseLayout) Arrangement.Top else Arrangement.Bottom,
    horizontalArrangement: Arrangement.Horizontal = Arrangement.Start,
    content: @Composable (item: T) -> Unit
) {
    val rows = items.chunked(columns)
    Column(modifier = modifier, verticalArrangement = verticalArrangement) {
        rows.forEachIndexed { rowindex, rowItems ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = horizontalArrangement) {
                rowItems.forEachIndexed { index, item ->
                    Box(
                        modifier = Modifier.weight(1f)
                    ) {
                        content(item)
                    }
                    if (index == rowItems.lastIndex && rowindex == rows.lastIndex) {
                        // Add a placeholder empty view
                        for (i in 0 until (columns - rowItems.size)) {
                            Spacer(
                                modifier = Modifier.weight(1f)
                            )
                        }
                    }
                }
            }
        }
    }
}

/** One group of credits: its title as a section tag, the names in a card (#87). */
@Composable
fun CreditCategorySection(
    title: String, names: List<String>, columns: Int = 2,
    thirdPartyInformation: List<ThirdPartyItem>? = null, navController: NavHostController? = null
) {
    val foregroundColor = MaterialTheme.colorScheme.onSurface

    ScreenTitle(title)
    SettingsCard {
        VerticalGrid(
            items = names.indices.toList(),
            columns = columns,
            verticalArrangement = Arrangement.spacedBy(4.dp),
            horizontalArrangement = Arrangement.spacedBy(2.dp),
            modifier = Modifier.padding(16.dp)
        ) {
            val name = names[it]
            val thirdPartyInfo = thirdPartyInformation?.get(it)
            if (thirdPartyInfo != null) {
                Column(
                    Modifier.fillMaxWidth()
                        .clickable {
                            navController!!.navigate(Route.ThirdPartyInfo(it))
                        }
                ) {
                    Text(
                        thirdPartyInfo.description,
                        color = foregroundColor, style = Typography.Body.Regular
                    )
                    Text(
                        thirdPartyInfo.copyright,
                        color = foregroundColor.copy(alpha = 0.7f),
                        style = Typography.Small
                    )
                }
            } else {
                Text(name, color = foregroundColor, style = Typography.Body.Regular)
            }
        }
    }
}

val CreditsScreenLite = UserSettingsMenu(
    title = R.string.credits_menu_title,
    navPath = "credits", registerNavPath = false,
    settings = listOf(
        userSettingNavigationItem(
            title = (R.string.credits_menu_contribute_translations_button),
            style = NavigationItemStyle.Misc,
            navigate = {
                it.context.openURI("https://i18n-keyboard.futo.org/")
            }),
        userSettingNavigationItem(
            title = (R.string.credits_menu_contribute_keyboard_layouts_button),
            style = NavigationItemStyle.Misc,
            navigate = {
                it.context.openURI("https://github.com/futo-org/futo-keyboard-layouts")
            }),
        userSettingNavigationItem(
            title = (R.string.credits_menu_contribute_code_button),
            style = NavigationItemStyle.Misc,
            navigate = {
                it.context.openURI("https://github.com/futo-org/android-keyboard/")
            })

    )
)

@Preview(showBackground = true, heightDp = 1600)
@Composable
fun CreditsScreen(navController: NavHostController = rememberNavController()) {
    val context = LocalContext.current
    ScrollableList {
        ScreenTitle(stringResource(R.string.credits_menu_title), showBack = true, navController)

        Text(
            stringResource(R.string.credits_menu_header_text),
            style = Typography.Body.RegularMl,
            modifier = Modifier.padding(16.dp, 0.dp, 16.dp, 12.dp)
        )

        CreditCategorySection(
            title = stringResource(R.string.credits_menu_team_translators_title),
            names = languageContribs
        )

        CreditCategorySection(
            title = stringResource(R.string.credits_menu_team_keyboard_layouts_title),
            names = layoutContribs
        )

        CreditCategorySection(
            title = stringResource(R.string.credits_menu_team_code_title),
            names = codeContribs
        )

        CreditCategorySection(
            title = stringResource(R.string.credits_menu_team_third_party_libraries_title2),
            columns = 1,
            names = ThirdPartyList.map { it.description },
            thirdPartyInformation = ThirdPartyList,
            navController = navController
        )

        ParagraphText(stringResource(R.string.credits_menu_nonaffiliation_notice), Modifier.padding(16.dp, 0.dp, 16.dp, 12.dp))

        CreditsScreenLite.render(showTitle = false)
        BottomSpacer()
    }
}