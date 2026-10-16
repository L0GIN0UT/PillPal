import 'package:flutter/services.dart';

/// Manufacturers whose firmware is known to stop background work and
/// delayed alarms (dontkillmyapp.com), lower-case, with a display name.
const Map<String, String> batteryRestrictiveVendors = {
  'xiaomi': 'Xiaomi',
  'redmi': 'Xiaomi',
  'poco': 'Xiaomi',
  'huawei': 'Huawei',
  'honor': 'Honor',
  'samsung': 'Samsung',
  'oppo': 'OPPO',
  'realme': 'realme',
  'oneplus': 'OnePlus',
  'vivo': 'vivo',
  'meizu': 'Meizu',
};

/// The display name of [manufacturer] if its phones need the battery hint
/// (TZ §2.3), else null.
String? batteryHintVendor(String? manufacturer) =>
    batteryRestrictiveVendors[manufacturer?.trim().toLowerCase()];

/// Small Android-only platform channel (`MainActivity.kt`): device
/// manufacturer and the battery-optimisation settings screen. Other
/// platforms answer null / false.
class DevicePlatform {
  /// Creates the channel wrapper.
  const DevicePlatform([this._channel = const MethodChannel(channelName)]);

  /// Channel name shared with `MainActivity.kt`.
  static const String channelName = 'pillpal/device';

  final MethodChannel _channel;

  /// `Build.MANUFACTURER`, or null where unavailable.
  Future<String?> manufacturer() async {
    try {
      return await _channel.invokeMethod<String>('manufacturer');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Opens the battery-optimisation settings (falls back to the app's
  /// settings page); false if nothing could be opened.
  Future<bool> openBatterySettings() async {
    try {
      return await _channel.invokeMethod<bool>('openBatterySettings') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
