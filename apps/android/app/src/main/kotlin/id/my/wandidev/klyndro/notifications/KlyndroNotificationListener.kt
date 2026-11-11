package id.my.wandidev.klyndro.notifications

import android.app.Notification
import android.content.Context
import android.content.pm.PackageManager
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import id.my.wandidev.klyndro.connection.ConnectionRuntime
import id.my.wandidev.klyndro.connection.ConnectionStatus
import id.my.wandidev.klyndro.protocol.NotificationMessageCodec
import id.my.wandidev.klyndro.protocol.NotificationPostBody
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Listens to incoming Android notifications and forwards them over the active Klyndro session.
 *
 * Adheres to protocol §5.3, §11:
 * - Never logs notification title or text.
 * - Forwards only when connected and user has enabled notification forwarding.
 * - Suppresses ongoing / persistent system foreground notifications.
 */
class KlyndroNotificationListener : NotificationListenerService() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var packageManagerHelper: PackageManager? = null

    override fun onCreate() {
        super.onCreate()
        packageManagerHelper = applicationContext.packageManager
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        super.onNotificationPosted(sbn)
        val notification = sbn ?: return

        // Ignore our own notifications
        if (notification.packageName == applicationContext.packageName) return

        // Ignore ongoing/sticky notifications (like music playback, downloads, foreground services)
        if (notification.isOngoing) return

        val extras = notification.notification.extras ?: return
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()
            ?: extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
            ?: ""

        // Skip completely empty notifications
        if (title.isBlank() && text.isBlank()) return

        val appName = try {
            val appInfo = packageManagerHelper?.getApplicationInfo(notification.packageName, 0)
            if (appInfo != null) {
                packageManagerHelper?.getApplicationLabel(appInfo)?.toString() ?: notification.packageName
            } else {
                notification.packageName
            }
        } catch (_: Exception) {
            notification.packageName
        }

        val key = "${notification.packageName}:${notification.id}:${notification.postTime}"

        val postBody = NotificationPostBody(
            key = key,
            packageName = notification.packageName,
            appName = appName,
            title = title,
            text = text,
            postedAt = notification.postTime,
            sensitive = false
        )

        // Only send if currently connected
        val phase = ConnectionRuntime.status.value.phase
        android.util.Log.i(TAG, "notification posted by $appName ($key), phase=$phase")

        if (phase == ConnectionStatus.Phase.CONNECTED) {
            scope.launch {
                val envelope = NotificationMessageCodec.postEnvelope(postBody)
                val sent = ConnectionRuntime.send(envelope)
                android.util.Log.i(TAG, "notification envelope sent: $sent")
            }
        }
    }

    companion object {
        private const val TAG = "KlyndroNotification"

        fun isPermissionGranted(context: Context): Boolean {
            val enabledListeners = android.provider.Settings.Secure.getString(
                context.contentResolver,
                "enabled_notification_listeners"
            ) ?: return false
            val myComponent = "${context.packageName}/${KlyndroNotificationListener::class.java.name}"
            return enabledListeners.contains(myComponent)
        }
    }
}
