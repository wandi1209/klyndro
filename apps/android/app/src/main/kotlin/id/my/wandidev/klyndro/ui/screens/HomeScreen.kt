package id.my.wandidev.klyndro.ui.screens

import androidx.compose.runtime.Composable
import androidx.compose.ui.res.stringResource
import id.my.wandidev.klyndro.R
import id.my.wandidev.klyndro.ui.InfoCard
import id.my.wandidev.klyndro.ui.ScreenColumn
import id.my.wandidev.klyndro.ui.ScreenHeader

@Composable
fun HomeScreen(versionName: String, identityFingerprint: String?) {
    ScreenColumn {
        ScreenHeader(
            title = stringResource(R.string.app_name),
            subtitle = stringResource(R.string.tagline)
        )

        InfoCard(
            title = stringResource(R.string.home_status_title),
            body = stringResource(R.string.home_status_not_connected) +
                "\n\n" + stringResource(R.string.home_status_hint)
        )

        InfoCard(
            title = stringResource(R.string.home_identity_title),
            body = if (identityFingerprint != null) {
                stringResource(R.string.home_identity_body, identityFingerprint)
            } else {
                stringResource(R.string.home_identity_unavailable)
            }
        )

        InfoCard(
            title = stringResource(R.string.home_build_title),
            body = stringResource(R.string.home_build_body) + "\n\nv" + versionName
        )

        InfoCard(
            title = stringResource(R.string.home_privacy_title),
            body = stringResource(R.string.home_privacy_body)
        )
    }
}
