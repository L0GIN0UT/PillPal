import Flutter
import UIKit
import UserNotifications
// Needed for FlutterLocalNotificationsPlugin.setPluginRegistrantCallback.
import flutter_local_notifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Shared with `DevicePlatform` (Dart) and `MainActivity.kt` (Android).
  private static let deviceChannel = "pillpal/device"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Reminders (docs/adr/0001-local-notifications.md §7): deliver
    // notification responses (taps, Taken / Snooze / Skip) to the plugin.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    // Notification actions run in a background engine, which needs the
    // plugins too (drift/path_provider, the notification plugin itself).
    FlutterLocalNotificationsPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PillPalDevice") {
      registerDeviceChannel(messenger: registrar.messenger())
    }
  }

  /// `timeSensitiveSetting`: "enabled", "disabled" or "notSupported"
  /// (iOS 15+, needs the Time Sensitive entitlement; ADR 0001 §6), nil on
  /// older systems.
  private func registerDeviceChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: AppDelegate.deviceChannel, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "timeSensitiveSetting" else {
        result(FlutterMethodNotImplemented)
        return
      }
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        var value: String?
        if #available(iOS 15.0, *) {
          switch settings.timeSensitiveSetting {
          case .enabled: value = "enabled"
          case .disabled: value = "disabled"
          default: value = "notSupported"
          }
        }
        DispatchQueue.main.async { result(value) }
      }
    }
  }
}
