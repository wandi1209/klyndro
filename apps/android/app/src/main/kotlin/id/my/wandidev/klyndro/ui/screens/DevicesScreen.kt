package id.my.wandidev.klyndro.ui.screens

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.media.projection.MediaProjectionManager
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.LaunchedEffect
import androidx.core.content.ContextCompat
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import id.my.wandidev.klyndro.R
import id.my.wandidev.klyndro.connection.ConnectionStatus
import id.my.wandidev.klyndro.connection.DiscoveredEntry
import id.my.wandidev.klyndro.ui.InfoCard
import id.my.wandidev.klyndro.ui.QrScannerDialog
import id.my.wandidev.klyndro.ui.ScreenColumn
import id.my.wandidev.klyndro.ui.ScreenHeader
import id.my.wandidev.klyndro.ui.KlyndroViewModel

@Composable
fun DevicesScreen(viewModel: KlyndroViewModel) {
    val status by viewModel.status.collectAsStateWithLifecycle()
    val discovered by viewModel.discovered.collectAsStateWithLifecycle()
    var started by remember { mutableStateOf(false) }
    var manualText by remember { mutableStateOf("") }
    var showQrScanner by remember { mutableStateOf(false) }
    var cameraPermissionDenied by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val cameraPermissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { granted ->
        cameraPermissionDenied = !granted
        if (granted) showQrScanner = true
    }
    val projectionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartActivityForResult()
    ) { result ->
        val data = result.data
        val pending = status.pendingMirrorStream
        if (result.resultCode == Activity.RESULT_OK && data != null) {
            viewModel.startStandardMirror(result.resultCode, data)
        } else if (pending != null) {
            viewModel.declineStandardMirror(pending.streamId)
        }
    }
    LaunchedEffect(status.pendingMirrorStream?.streamId) {
        val pending = status.pendingMirrorStream ?: return@LaunchedEffect
        val manager = context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as? MediaProjectionManager
        if (manager != null) {
            projectionLauncher.launch(manager.createScreenCaptureIntent())
        } else {
            viewModel.declineStandardMirror(pending.streamId)
        }
    }
    val filePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.OpenDocument()
    ) { uri: Uri? ->
        uri?.let { viewModel.sendFileUri(it) }
    }

    ScreenColumn {
        ScreenHeader(
            title = stringResource(R.string.pairing_title),
            subtitle = stringResource(R.string.pairing_body)
        )

        Button(
            onClick = {
                val granted = ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.CAMERA
                ) == PackageManager.PERMISSION_GRANTED
                if (granted) {
                    cameraPermissionDenied = false
                    showQrScanner = true
                } else {
                    cameraPermissionLauncher.launch(Manifest.permission.CAMERA)
                }
            },
            modifier = Modifier.fillMaxWidth()
        ) {
            Text(stringResource(R.string.qr_scan_button))
        }
        if (cameraPermissionDenied) {
            Text(
                text = stringResource(R.string.qr_camera_denied),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error
            )
        }

        // Connection control. The service is what keeps the link alive after leaving the app.
        OutlinedCard(modifier = Modifier.fillMaxWidth()) {
            Column(
                modifier = Modifier.padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                Text(
                    text = stringResource(R.string.devices_status, status.phase.readable()),
                    style = MaterialTheme.typography.titleSmall
                )
                status.peerName?.let { peer ->
                    Text(
                        text = stringResource(R.string.devices_connected, peer),
                        style = MaterialTheme.typography.bodyMedium
                    )
                }
                status.identityShort?.let { identity ->
                    Text(
                        text = "This device: $identity",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
                status.lastError?.let { error ->
                    Text(
                        text = error,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error
                    )
                }

                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (status.serviceRunning) {
                        OutlinedButton(onClick = {
                            viewModel.stopService()
                            started = false
                        }) { Text(stringResource(R.string.devices_stop_service)) }
                    } else {
                        Button(onClick = {
                            viewModel.startService()
                            started = true
                        }) { Text(stringResource(R.string.devices_start_service)) }
                    }
                    if (status.standardMirroring) {
                        OutlinedButton(onClick = { viewModel.stopStandardMirror() }) {
                            Text(stringResource(R.string.standard_mirror_stop))
                        }
                    }
                }
            }
        }

        if (discovered.isEmpty()) {
            InfoCard(
                title = stringResource(R.string.pairing_title),
                body = stringResource(R.string.pairing_none_found)
            )
            // Manual USB/Direct connect fallback (F01)
            OutlinedButton(
                onClick = { viewModel.pair("127.0.0.1", 47823, null) },
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("Pair via USB Cable (127.0.0.1:47823)")
            }
        } else {
            discovered.forEach { entry ->
                OutlinedCard(modifier = Modifier.fillMaxWidth()) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(16.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(entry.name, style = MaterialTheme.typography.titleSmall)
                            Text(
                                text = "${entry.host}:${entry.port}",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Button(onClick = { viewModel.pair(entry.host, entry.port, entry.hostName) }) {
                                Text("Pair")
                            }
                            OutlinedButton(
                                onClick = {
                                    viewModel.pair(
                                        host = "127.0.0.1",
                                        port = entry.port,
                                        hostName = null,
                                        persistHost = entry.host,
                                        persistHostName = entry.hostName
                                    )
                                }
                            ) {
                                Text("USB")
                            }
                        }
                    }
                }
            }
        }

        InfoCard(
            title = stringResource(R.string.clipboard_status_title),
            body = buildString {
                append(stringResource(R.string.clipboard_sent, status.clipboardSentCount))
                append('\n')
                append(stringResource(R.string.clipboard_applied, status.clipboardAppliedCount))
                viewModel.clipboardPreview?.let {
                    append('\n')
                    append("Clipboard: $it")
                }
                append('\n')
                append(stringResource(R.string.clipboard_foreground_only))
            }
        )

        Button(
            onClick = { viewModel.sendClipboardNow() },
            modifier = Modifier.fillMaxWidth()
        ) {
            Text(stringResource(R.string.clipboard_send_now))
        }

        // Explicit text send: the one path that works regardless of Android's clipboard rules.
        OutlinedTextField(
            value = manualText,
            onValueChange = { manualText = it },
            modifier = Modifier.fillMaxWidth(),
            label = { Text(stringResource(R.string.clipboard_send_text_label)) },
            singleLine = true
        )
        Button(
            onClick = {
                viewModel.sendTextToMac(manualText)
                manualText = ""
            },
            modifier = Modifier.fillMaxWidth(),
            enabled = manualText.isNotBlank()
        ) {
            Text(stringResource(R.string.clipboard_send_text_action))
        }

        OutlinedButton(
            onClick = { filePicker.launch(arrayOf("*/*")) },
            modifier = Modifier.fillMaxWidth(),
            enabled = status.phase == ConnectionStatus.Phase.CONNECTED
        ) {
            Text("Send File to Mac…")
        }

        viewModel.clipboardActionMessage?.let { message ->
            Text(
                text = message,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.primary
            )
        }
    }

    if (showQrScanner) {
        QrScannerDialog(
            onScanned = { payload ->
                showQrScanner = false
                viewModel.pair(
                    host = payload.host,
                    port = payload.port,
                    hostName = null,
                    expectedFingerprint = payload.fingerprint.hex
                )
            },
            onDismiss = { showQrScanner = false }
        )
    }

    val code = status.pairingCode
    if (code != null) {
        AlertDialog(
            onDismissRequest = { viewModel.confirmPairing(false) },
            title = { Text(stringResource(R.string.pairing_code_title)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = formatCode(code),
                        style = MaterialTheme.typography.displaySmall,
                        fontWeight = FontWeight.SemiBold
                    )
                    Text(
                        text = stringResource(
                            R.string.pairing_code_body,
                            status.peerName ?: "The Mac"
                        )
                    )
                }
            },
            confirmButton = {
                TextButton(onClick = { viewModel.confirmPairing(true) }) {
                    Text(stringResource(R.string.pairing_confirm))
                }
            },
            dismissButton = {
                TextButton(onClick = { viewModel.confirmPairing(false) }) {
                    Text(stringResource(R.string.pairing_cancel))
                }
            }
        )
    }
}

/** `123456` becomes `123 456`, easier to compare aloud without transposing digits. */
private fun formatCode(code: String): String =
    if (code.length == 6) "${code.take(3)} ${code.drop(3)}" else code

private fun ConnectionStatus.Phase.readable(): String = when (this) {
    ConnectionStatus.Phase.IDLE -> "idle"
    ConnectionStatus.Phase.SEARCHING -> "searching"
    ConnectionStatus.Phase.CONNECTING -> "connecting"
    ConnectionStatus.Phase.PAIRING -> "pairing"
    ConnectionStatus.Phase.CONNECTED -> "connected"
    ConnectionStatus.Phase.STOPPED -> "stopped"
    ConnectionStatus.Phase.ERROR -> "error"
}
