import 'package:flutter/services.dart';

/// The native `pillpal/push` channel (`MainActivity.kt`, `AppDelegate.swift`).
const MethodChannel pushChannel = MethodChannel('pillpal/push');

/// Keeps only the string entries of push data: the providers hand out maps
/// of `String?`/`Object?`, and a payload with anything else is not ours.
Map<String, String> stringData(Map<Object?, Object?>? raw) {
  final data = <String, String>{};
  raw?.forEach((key, value) {
    if (key is String && value is String) {
      data[key] = value;
    }
  });
  return data;
}
