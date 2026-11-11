package com.pillpal.pillpal

import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the Flutter UI and the small `pillpal/device` channel used by the
 * reminder onboarding (docs/adr/0001-local-notifications.md): the device
 * manufacturer (OEM battery hint) and the battery-optimisation settings.
 * The `pillpal/push` channel tells the push provider choice whether Google
 * Play services exist (docs/adr/0008-push-delivery.md §1). The
 * `pillpal/reports` channel is in [ReportChannel].
 */
class MainActivity : FlutterActivity() {
    private var reportChannel: ReportChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Open, save and share the stored reports (docs/adr/0019 §5).
        reportChannel = ReportChannel(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "manufacturer" -> result.success(Build.MANUFACTURER)
                    "openBatterySettings" -> result.success(openBatterySettings())
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PUSH_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "gmsAvailable" -> result.success(googlePlayServicesAvailable())
                    else -> result.notImplemented()
                }
            }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (reportChannel?.onActivityResult(requestCode, resultCode, data) == true) return
        @Suppress("DEPRECATION")
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        reportChannel?.dispose()
        reportChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    /**
     * Google Play services is installed and enabled. Checked through the
     * package manager: no Google library is needed for the answer, so a build
     * without Firebase settings behaves the same.
     */
    private fun googlePlayServicesAvailable(): Boolean = try {
        packageManager.getApplicationInfo(GMS_PACKAGE, 0).enabled
    } catch (error: PackageManager.NameNotFoundException) {
        false
    }

    /** The battery-optimisation list, else this app's settings page. */
    private fun openBatterySettings(): Boolean {
        val intents = listOf(
            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", packageName, null),
            ),
        )
        for (intent in intents) {
            try {
                startActivity(intent)
                return true
            } catch (error: ActivityNotFoundException) {
                // Not available on this firmware: try the next screen.
            }
        }
        return false
    }

    private companion object {
        const val CHANNEL = "pillpal/device"
        const val PUSH_CHANNEL = "pillpal/push"
        const val GMS_PACKAGE = "com.google.android.gms"
    }
}
