package id.my.wandidev.klyndro.ui.screens

import android.content.Intent
import android.net.Uri
import android.provider.Settings
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import id.my.wandidev.klyndro.R
import id.my.wandidev.klyndro.ui.InfoCard
import id.my.wandidev.klyndro.ui.ScreenColumn
import id.my.wandidev.klyndro.ui.ScreenHeader

@Composable
fun PermissionsScreen() {
    val context = LocalContext.current

    ScreenColumn {
        ScreenHeader(
            title = stringResource(R.string.permissions_title),
            subtitle = stringResource(R.string.permissions_intro)
        )

        InfoCard(
            title = stringResource(R.string.permissions_network_title),
            body = stringResource(R.string.permissions_network_body),
            badge = stringResource(R.string.permissions_state_granted)
        )

        InfoCard(
            title = stringResource(R.string.permissions_clipboard_title),
            body = stringResource(R.string.permissions_clipboard_body),
            badge = stringResource(R.string.permissions_state_not_required)
        )

        InfoCard(
            title = stringResource(R.string.permissions_notifications_title),
            body = stringResource(R.string.permissions_notifications_body),
            badge = stringResource(R.string.permissions_state_not_required)
        )

        Spacer(modifier = Modifier.height(4.dp))

        Button(
            onClick = {
                val intent = Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", context.packageName, null)
                )
                context.startActivity(intent)
            }
        ) {
            Text(stringResource(R.string.permissions_open_settings))
        }
    }
}
