package id.my.wandidev.klyndro.ui.screens

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import id.my.wandidev.klyndro.R
import id.my.wandidev.klyndro.ui.InfoCard
import id.my.wandidev.klyndro.ui.ScreenColumn
import id.my.wandidev.klyndro.ui.ScreenHeader
import id.my.wandidev.klyndro.ui.SettingRow

@Composable
fun SettingsScreen(
    serviceRunning: Boolean,
    clipboardSyncEnabled: Boolean,
    notificationsEnabled: Boolean,
    onClipboardSyncChange: (Boolean) -> Unit,
    onNotificationsChange: (Boolean) -> Unit
) {
    ScreenColumn {
        ScreenHeader(title = stringResource(R.string.settings_features_title))

        SettingRow(
            title = stringResource(R.string.settings_clipboard_title),
            supporting = stringResource(R.string.settings_clipboard_body),
            checked = clipboardSyncEnabled,
            onCheckedChange = onClipboardSyncChange
        )

        SettingRow(
            title = stringResource(R.string.settings_notifications_title),
            supporting = stringResource(R.string.settings_notifications_body),
            checked = notificationsEnabled,
            onCheckedChange = onNotificationsChange
        )

        ScreenHeader(title = stringResource(R.string.settings_service_title))

        InfoCard(
            title = stringResource(
                if (serviceRunning) R.string.settings_service_running else R.string.settings_service_not_running
            ),
            body = stringResource(R.string.settings_service_body)
        )
    }
}
