package id.my.wandidev.klyndro.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.PrimaryScrollableTabRow
import androidx.compose.material3.Tab
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel
import id.my.wandidev.klyndro.R
import id.my.wandidev.klyndro.ui.screens.DevicesScreen
import id.my.wandidev.klyndro.ui.screens.HelpScreen
import id.my.wandidev.klyndro.ui.screens.HomeScreen
import id.my.wandidev.klyndro.ui.screens.PermissionsScreen
import id.my.wandidev.klyndro.ui.screens.SettingsScreen

private val tabLabels = listOf(
    R.string.nav_home,
    R.string.nav_devices,
    R.string.nav_permissions,
    R.string.nav_settings,
    R.string.nav_help
)

/**
 * Root of the Android UI.
 *
 * A `TabRow` keeps the shell dependency-free: five primary destinations, no icon
 * library, no navigation graph to maintain while the screens are still placeholders.
 */
@Composable
fun KlyndroApp(viewModel: KlyndroViewModel = viewModel()) {
    var selectedTab by rememberSaveable { mutableIntStateOf(0) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .windowInsetsPadding(WindowInsets.safeDrawing)
    ) {
        PrimaryScrollableTabRow(selectedTabIndex = selectedTab, edgePadding = 8.dp) {
            tabLabels.forEachIndexed { index, labelRes ->
                Tab(
                    selected = selectedTab == index,
                    onClick = { selectedTab = index },
                    text = {
                        // Five destinations do not fit on a 360 dp screen. A scrollable row keeps
                        // full labels readable instead of clipping them to "Devic…".
                        Text(text = stringResource(labelRes), maxLines = 1)
                    }
                )
            }
        }

        when (selectedTab) {
            0 -> HomeScreen(
                versionName = viewModel.versionName,
                identityFingerprint = viewModel.identityFingerprint
            )
            1 -> DevicesScreen(viewModel)
            2 -> PermissionsScreen()
            3 -> SettingsScreen(
                clipboardSyncEnabled = viewModel.clipboardSyncEnabled,
                notificationsEnabled = viewModel.notificationsEnabled,
                onClipboardSyncChange = viewModel::updateClipboardSyncEnabled,
                onNotificationsChange = viewModel::updateNotificationsEnabled
            )
            else -> HelpScreen(
                versionName = viewModel.versionName,
                applicationId = viewModel.applicationId
            )
        }
    }
}
