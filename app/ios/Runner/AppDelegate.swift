import Flutter
import UIKit
import UserNotifications
// Needed for FlutterLocalNotificationsPlugin.setPluginRegistrantCallback.
import flutter_local_notifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Shared with `DevicePlatform` (Dart) and `MainActivity.kt` (Android).
  private static let deviceChannel = "pillpal/device"

  /// How long a notification action may run in the background (iOS grants
  /// about 30 s to a background task).
  private static let actionWindow: TimeInterval = 25

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Reminders (docs/adr/0001-local-notifications.md §7): deliver
    // notification responses (taps, Taken / Snooze / Skip) to the plugin.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Taken / Snooze / Skip run Dart in a background engine (ADR 0001 §7),
  /// but the plugin calls the completion handler as soon as it has started
  /// that engine, after which iOS may suspend the app in the middle of the
  /// database write. A background task keeps the app running for
  /// `actionWindow`; it ends then or when iOS expires it, whichever is first.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    if response.actionIdentifier != UNNotificationDefaultActionIdentifier
      && response.actionIdentifier != UNNotificationDismissActionIdentifier {
      keepRunningForAction()
    }
    super.userNotificationCenter(
      center, didReceive: response, withCompletionHandler: completionHandler)
  }

  private func keepRunningForAction() {
    let application = UIApplication.shared
    var task = UIBackgroundTaskIdentifier.invalid
    let end: () -> Void = {
      guard task != .invalid else { return }
      application.endBackgroundTask(task)
      task = .invalid
    }
    task = application.beginBackgroundTask(
      withName: "pillpal.reminder-action", expirationHandler: end)
    DispatchQueue.main.asyncAfter(deadline: .now() + AppDelegate.actionWindow, execute: end)
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
