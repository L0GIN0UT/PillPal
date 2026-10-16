import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// User-facing app preferences (persisted from milestone 2.1).
@immutable
class AppSettings {
  /// Creates settings; defaults follow the system.
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.seniorMode = false,
    this.locale,
  });

  /// Light, dark or system theme.
  final ThemeMode themeMode;

  /// Larger text and controls (TZ §2.6).
  final bool seniorMode;

  /// Explicit app language; `null` follows the system.
  final Locale? locale;

  /// Returns a copy with the given fields replaced.
  AppSettings copyWith({
    ThemeMode? themeMode,
    bool? seniorMode,
    Locale? locale,
    bool resetLocale = false,
  }) {
    return AppSettings(
      themeMode: themeMode ?? this.themeMode,
      seniorMode: seniorMode ?? this.seniorMode,
      locale: resetLocale ? null : (locale ?? this.locale),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.themeMode == themeMode &&
      other.seniorMode == seniorMode &&
      other.locale == locale;

  @override
  int get hashCode => Object.hash(themeMode, seniorMode, locale);
}

/// Holds and updates [AppSettings].
class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() => const AppSettings();

  /// Switches between system, light and dark theme.
  void setThemeMode(ThemeMode mode) {
    state = state.copyWith(themeMode: mode);
  }

  /// Turns senior mode on or off.
  void setSeniorMode({required bool enabled}) {
    state = state.copyWith(seniorMode: enabled);
  }

  /// Sets the app language; `null` follows the system.
  void setLocale(Locale? locale) {
    state = locale == null
        ? state.copyWith(resetLocale: true)
        : state.copyWith(locale: locale);
  }
}

/// App settings provider.
final settingsProvider = NotifierProvider<SettingsController, AppSettings>(
  SettingsController.new,
);
