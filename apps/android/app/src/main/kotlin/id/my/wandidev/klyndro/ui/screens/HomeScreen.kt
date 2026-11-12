package id.my.wandidev.klyndro.ui.screens

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import id.my.wandidev.klyndro.R
import id.my.wandidev.klyndro.connection.ConnectionStatus
import id.my.wandidev.klyndro.connection.ConnectionStatus.Phase
import id.my.wandidev.klyndro.ui.InfoCard
import id.my.wandidev.klyndro.ui.KlyndroLogo
import id.my.wandidev.klyndro.ui.PillTone
import id.my.wandidev.klyndro.ui.ScreenColumn
import id.my.wandidev.klyndro.ui.StatusPill

@Composable
fun HomeScreen(versionName: String, identityFingerprint: String?, status: ConnectionStatus) {
    ScreenColumn {
        Row(verticalAlignment = Alignment.CenterVertically) {
            KlyndroLogo(size = 64.dp)
            Spacer(modifier = Modifier.width(16.dp))
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    text = stringResource(R.string.app_name),
                    style = MaterialTheme.typography.headlineMedium
                )
                Text(
                    text = stringResource(R.string.tagline),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }

        val (label, tone) = when (status.phase) {
            Phase.CONNECTED -> (
                status.peerName?.let { stringResource(R.string.status_connected_to, it) }
                    ?: stringResource(R.string.status_connected)
                ) to PillTone.POSITIVE
            Phase.SEARCHING -> stringResource(R.string.status_searching) to PillTone.NEUTRAL
            Phase.CONNECTING -> stringResource(R.string.status_connecting) to PillTone.NEUTRAL
            Phase.PAIRING -> stringResource(R.string.status_pairing) to PillTone.NEUTRAL
            Phase.STOPPED -> stringResource(R.string.status_stopped) to PillTone.NEUTRAL
            Phase.ERROR -> stringResource(R.string.status_error) to PillTone.ERROR
            Phase.IDLE -> stringResource(R.string.status_idle) to PillTone.NEUTRAL
        }
        StatusPill(text = label, tone = tone)

        InfoCard(
            title = stringResource(R.string.home_status_title),
            body = if (status.phase == Phase.CONNECTED) {
                stringResource(R.string.clipboard_sent, status.clipboardSentCount) + "\n" +
                    stringResource(R.string.clipboard_applied, status.clipboardAppliedCount)
            } else {
                stringResource(R.string.home_status_hint)
            }
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
