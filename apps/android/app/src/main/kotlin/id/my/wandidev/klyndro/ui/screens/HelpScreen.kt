package id.my.wandidev.klyndro.ui.screens

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import id.my.wandidev.klyndro.R
import id.my.wandidev.klyndro.ui.InfoCard
import id.my.wandidev.klyndro.ui.ScreenColumn
import id.my.wandidev.klyndro.ui.ScreenHeader

@Composable
fun HelpScreen(versionName: String, applicationId: String) {
    ScreenColumn {
        ScreenHeader(title = stringResource(R.string.help_title))

        InfoCard(
            title = stringResource(R.string.help_battery_title),
            body = stringResource(R.string.help_battery_body)
        )

        InfoCard(
            title = stringResource(R.string.help_clipboard_title),
            body = stringResource(R.string.help_clipboard_body)
        )

        InfoCard(
            title = stringResource(R.string.help_mirroring_title),
            body = stringResource(R.string.help_mirroring_body)
        )

        ScreenHeader(title = stringResource(R.string.about_title))

        InfoCard(
            title = stringResource(R.string.about_version),
            body = "v$versionName\n$applicationId"
        )

        InfoCard(
            title = stringResource(R.string.about_license),
            body = stringResource(R.string.about_license_value)
        )
    }
}
