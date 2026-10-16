import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

/// The native provider of the Today widget (android/app/src/main/kotlin).
const String todayWidgetProvider = 'com.pillpal.pillpal.TodayWidgetProvider';

/// The home-screen widget platform; [PluginHomeWidgetChannel] in the app, a
/// fake in tests.
abstract interface class HomeWidgetChannel {
  /// Whether this platform has the widget (Android only in milestone 2.4;
  /// the iOS WidgetKit extension is a follow-up, docs/phase2-plan.md).
  bool get isSupported;

  /// Stores [data] for the native provider.
  Future<void> save(Map<String, String> data);

  /// Redraws the widget now.
  Future<void> redraw();

  /// Redraws the widget at [instants] too (replaces earlier ones).
  Future<void> scheduleRedraws(List<DateTime> instants);

  /// Taps on the widget while the app runs.
  Stream<void> get taps;

  /// Whether the app was started by a tap on the widget.
  Future<bool> launchedFromWidget();
}

/// [HomeWidgetChannel] over the `home_widget` plugin.
class PluginHomeWidgetChannel implements HomeWidgetChannel {
  /// Creates the channel.
  const PluginHomeWidgetChannel();

  @override
  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<void> save(Map<String, String> data) async {
    for (final entry in data.entries) {
      await HomeWidget.saveWidgetData<String>(entry.key, entry.value);
    }
  }

  @override
  Future<void> redraw() async {
    await HomeWidget.updateWidget(qualifiedAndroidName: todayWidgetProvider);
  }

  @override
  Future<void> scheduleRedraws(List<DateTime> instants) async {
    await HomeWidget.scheduleWidgetUpdates(
      instants,
      qualifiedAndroidName: todayWidgetProvider,
    );
  }

  @override
  Stream<void> get taps => HomeWidget.widgetClicked;

  @override
  Future<bool> launchedFromWidget() async =>
      await HomeWidget.initiallyLaunchedFromHomeWidget() != null;
}
