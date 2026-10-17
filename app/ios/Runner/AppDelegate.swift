import Flutter
import UIKit
import UserNotifications
// Needed for FlutterLocalNotificationsPlugin.setPluginRegistrantCallback.
import flutter_local_notifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  /// Shared with `DevicePlatform` (Dart) and `MainActivity.kt` (Android).
  private static let deviceChannel = "pillpal/device"

  /// Shared with `ApnsChannel` (Dart): the raw APNs token and alert taps
  /// (docs/adr/0008-push-delivery.md §1).
  private static let pushChannelName = "pillpal/push"

  /// How long Dart may take to hand out the APNs token before the request
  /// is answered with "none" (no network, or Push is not enabled for the
  /// signed build); the next trigger asks again.
  private static let apnsTokenTimeout: TimeInterval = 20

  private var pushChannel: FlutterMethodChannel?
  private var pendingApnsResult: FlutterResult?
  /// The alert that launched the app, until Dart asks for it; after that,
  /// taps are delivered live.
  private var launchTap: [String: String]?
  private var dartListensForTaps = false

  /// How long a notification action may run in the background (iOS grants
  /// about 30 s to a background task). Besides the local write it covers the
  /// push-only flush of the outbox that the Dart handler runs afterwards
  /// (ADR 0001 addendum 3.7); that flush is cut at 20 s
  /// (`iosFlushBudget`), so it ends before this window does.
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
    // Our own remote alerts are not the plugin's notifications: it would
    // neither know nor complete them, so they are finished here.
    if AppDelegate.alertData(from: response.notification) != nil {
      recordAlertTap(response)
      completionHandler()
      return
    }
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
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PillPalPush") {
      registerPushChannel(messenger: registrar.messenger())
    }
  }

  // MARK: - Push (APNs)

  /// `registerApns` answers with `{token, environment}` (or nil),
  /// `unregisterApns` gives the registration back, `initialTap` returns the
  /// alert that launched the app. Native calls into Dart: `token` (a new
  /// token), `message` (an alert while the app is in the foreground), `tap`.
  private func registerPushChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: AppDelegate.pushChannelName, binaryMessenger: messenger)
    pushChannel = channel
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "registerApns":
        self?.requestApnsToken(result: result)
      case "unregisterApns":
        UIApplication.shared.unregisterForRemoteNotifications()
        result(nil)
      case "initialTap":
        result(self?.takeLaunchTap())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func requestApnsToken(result: @escaping FlutterResult) {
    finishApnsRequest(nil)
    pendingApnsResult = result
    UIApplication.shared.registerForRemoteNotifications()
    DispatchQueue.main.asyncAfter(deadline: .now() + AppDelegate.apnsTokenTimeout) { [weak self] in
      self?.finishApnsRequest(nil)
    }
  }

  private func finishApnsRequest(_ value: [String: String]?) {
    let result = pendingApnsResult
    pendingApnsResult = nil
    result?(value)
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    let value = ["token": token, "environment": AppDelegate.apnsEnvironment()]
    if pendingApnsResult != nil {
      finishApnsRequest(value)
    } else {
      pushChannel?.invokeMethod("token", arguments: value)
    }
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    finishApnsRequest(nil)
    super.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
  }

  /// A token of the wrong environment is refused by Apple, so the backend
  /// needs the one this build uses: the provisioning profile of a development
  /// or ad-hoc build says it, App Store and TestFlight builds carry none
  /// (production). The simulator uses the sandbox.
  private static func apnsEnvironment() -> String {
    #if targetEnvironment(simulator)
    return "sandbox"
    #else
    guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
      let raw = try? Data(contentsOf: URL(fileURLWithPath: path)),
      let text = String(data: raw, encoding: .isoLatin1),
      let start = text.range(of: "<?xml"),
      let end = text.range(of: "</plist>"),
      let plist = text[start.lowerBound..<end.upperBound].data(using: .utf8),
      let profile = try? PropertyListSerialization.propertyList(from: plist, options: [], format: nil)
        as? [String: Any],
      let entitlements = profile["Entitlements"] as? [String: Any],
      let environment = entitlements["aps-environment"] as? String
    else {
      return "production"
    }
    return environment == "development" ? "sandbox" : "production"
    #endif
  }

  /// An alert push shown while the app is open: a banner as well (the
  /// system would hide it), and Dart refreshes the data behind it.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if let data = AppDelegate.alertData(from: notification) {
      pushChannel?.invokeMethod("message", arguments: data)
      if #available(iOS 14.0, *) {
        completionHandler([.banner, .list, .sound])
      } else {
        completionHandler([.alert, .sound])
      }
      return
    }
    super.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
  }

  private func recordAlertTap(_ response: UNNotificationResponse) {
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      let data = AppDelegate.alertData(from: response.notification)
    else {
      return
    }
    if dartListensForTaps {
      pushChannel?.invokeMethod("tap", arguments: data)
    } else {
      launchTap = data
    }
  }

  private func takeLaunchTap() -> [String: String]? {
    dartListensForTaps = true
    let tap = launchTap
    launchTap = nil
    return tap
  }

  /// The payload of a remote alert of this app, or nil for any other
  /// notification (the reminders are local and carry their own payload).
  /// Everything but `aps` is handed to Dart, which accepts exactly the known
  /// keys: an unexpected one makes it ignore the push, as on Android.
  private static func alertData(from notification: UNNotification) -> [String: String]? {
    guard notification.request.trigger is UNPushNotificationTrigger else {
      return nil
    }
    var data: [String: String] = [:]
    for (key, value) in notification.request.content.userInfo {
      guard let name = key as? String, name != "aps" else {
        continue
      }
      if let text = value as? String {
        data[name] = text
      } else if let number = value as? NSNumber {
        data[name] = number.stringValue
      } else {
        data[name] = "?"  // not a payload value: Dart rejects the whole push
      }
    }
    return data["v"] != nil && data["t"] != nil ? data : nil
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
