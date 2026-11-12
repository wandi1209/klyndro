package id.my.wandidev.klyndro.mirror

import android.content.Context
import android.content.Intent
import id.my.wandidev.klyndro.protocol.AppLauncherMessages
import id.my.wandidev.klyndro.protocol.StandardAppEntry

/**
 * Lists and launches user-installed launcher apps on Android without ADB (ADR 0010).
 */
object AppLauncher {

    fun listLaunchableApps(context: Context): List<StandardAppEntry> {
        val pm = context.packageManager
        val intent = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_LAUNCHER)
        }
        val resolved = pm.queryIntentActivities(intent, 0)
        val seen = HashSet<String>()
        val result = ArrayList<StandardAppEntry>()
        for (info in resolved) {
            val pkg = info.activityInfo?.packageName ?: continue
            if (!AppLauncherMessages.isValidPackageName(pkg) || !seen.add(pkg)) continue
            val label = info.loadLabel(pm).toString().trim()
            if (label.isEmpty()) continue
            result.add(StandardAppEntry(pkg, label))
        }
        return result
            .sortedBy { it.label.lowercase() }
            .take(AppLauncherMessages.MAX_APPS)
    }

    fun launchApp(context: Context, packageName: String): Boolean {
        if (!AppLauncherMessages.isValidPackageName(packageName)) return false
        val launchIntent = context.packageManager.getLaunchIntentForPackage(packageName) ?: return false
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return runCatching {
            context.startActivity(launchIntent)
            true
        }.getOrDefault(false)
    }
}
