package id.my.wandidev.klyndro.mirror

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.ComponentName
import android.content.Context
import android.graphics.Path
import android.os.Build
import android.provider.Settings
import android.view.accessibility.AccessibilityEvent
import id.my.wandidev.klyndro.protocol.InputActionBody
import id.my.wandidev.klyndro.protocol.InputActionKind
import id.my.wandidev.klyndro.protocol.InputGestureBody
import id.my.wandidev.klyndro.protocol.InputGestureKind

/**
 * Executes user-initiated Standard Mode remote gestures and navigation actions without ADB
 * (ADR 0010, protocol §5.6a). Never enabled silently: Android requires explicit user consent in
 * System Accessibility Settings.
 */
class KlyndroAccessibilityService : AccessibilityService() {

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) = Unit

    override fun onInterrupt() = Unit

    override fun onDestroy() {
        if (instance === this) instance = null
        super.onDestroy()
    }

    fun executeGesture(gesture: InputGestureBody): Boolean {
        val metrics = resources.displayMetrics
        val w = metrics.widthPixels.toFloat()
        val h = metrics.heightPixels.toFloat()
        if (w <= 0f || h <= 0f) return false

        val startX = (gesture.x * w).coerceIn(0f, w - 1f)
        val startY = (gesture.y * h).coerceIn(0f, h - 1f)

        val path = Path().apply {
            moveTo(startX, startY)
            if (gesture.kind == InputGestureKind.SWIPE && gesture.endX != null && gesture.endY != null) {
                val endX = (gesture.endX * w).coerceIn(0f, w - 1f)
                val endY = (gesture.endY * h).coerceIn(0f, h - 1f)
                lineTo(endX, endY)
            }
        }

        val stroke = GestureDescription.StrokeDescription(
            path,
            0L,
            gesture.durationMs.toLong()
        )
        val description = GestureDescription.Builder().addStroke(stroke).build()
        return dispatchGesture(description, null, null)
    }

    fun executeAction(action: InputActionBody): Boolean {
        val globalAction = when (action.action) {
            InputActionKind.BACK -> GLOBAL_ACTION_BACK
            InputActionKind.HOME -> GLOBAL_ACTION_HOME
            InputActionKind.RECENTS -> GLOBAL_ACTION_RECENTS
            InputActionKind.NOTIFICATIONS -> GLOBAL_ACTION_NOTIFICATIONS
            InputActionKind.LOCK_SCREEN -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) GLOBAL_ACTION_LOCK_SCREEN
                else return false
            }
        }
        return performGlobalAction(globalAction)
    }

    companion object {
        @Volatile
        private var instance: KlyndroAccessibilityService? = null

        fun isEnabled(context: Context): Boolean {
            if (instance != null) return true
            val expected = ComponentName(context, KlyndroAccessibilityService::class.java).flattenToString()
            val enabled = Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
            ) ?: return false
            return enabled.split(':').any { it.equals(expected, ignoreCase = true) }
        }

        fun dispatch(gesture: InputGestureBody): Boolean =
            instance?.executeGesture(gesture) ?: false

        fun dispatch(action: InputActionBody): Boolean =
            instance?.executeAction(action) ?: false
    }
}
