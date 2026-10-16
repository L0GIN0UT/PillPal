package com.pillpal.pillpal

import android.content.ActivityNotFoundException
import android.content.Intent
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
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "manufacturer" -> result.success(Build.MANUFACTURER)
                    "openBatterySettings" -> result.success(openBatterySettings())
                    else -> result.notImplemented()
                }
            }
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
    }
}
