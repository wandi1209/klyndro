package id.my.wandidev.klyndro.ui.screens

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import id.my.wandidev.klyndro.R
import id.my.wandidev.klyndro.mirror.KlyndroAccessibilityService
import id.my.wandidev.klyndro.notifications.KlyndroNotificationListener
import id.my.wandidev.klyndro.ui.InfoCard
import id.my.wandidev.klyndro.ui.ScreenColumn
import id.my.wandidev.klyndro.ui.ScreenHeader

@Composable
fun PermissionsScreen() {
    val context = LocalContext.current
    val hasNotifAccess = KlyndroNotificationListener.isPermissionGranted(context)
    val hasAccessibility = KlyndroAccessibilityService.isEnabled(context)
    var hasPostNotif by remember {
        mutableStateOf(
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.POST_NOTIFICATIONS
                ) == PackageManager.PERMISSION_GRANTED
            } else {
                true
            }
        )
    }
    val postNotifLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { granted ->
        hasPostNotif = granted
    }

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
            badge = if (hasNotifAccess) "Granted" else "Requires grant"
        )

        Spacer(modifier = Modifier.height(4.dp))

        if (!hasNotifAccess) {
            Button(
                onClick = {
                    val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                    context.startActivity(intent)
                }
            ) {
                Text("Grant Notification Access")
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !hasPostNotif) {
            InfoCard(
                title = stringResource(R.string.permissions_post_notifications_title),
                body = stringResource(R.string.permissions_post_notifications_body),
                badge = "Requires grant"
            )
            Button(
                onClick = {
                    postNotifLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                }
            ) {
                Text(stringResource(R.string.permissions_grant_post_notifications))
            }
        }

        if (!hasAccessibility) {
            Button(
                onClick = {
                    context.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                }
            ) {
                Text(stringResource(R.string.permissions_open_accessibility))
            }
        }

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
