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

  /// Deletes [keys] from the widget storage.
  Future<void> remove(List<String> keys);

  /// Whether the user has placed the widget on a home screen.
  Future<bool> hasWidgets();

  /// Redraws the widget now.
  Future<void> redraw();

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
  Future<void> remove(List<String> keys) async {
    for (final key in keys) {
      await HomeWidget.saveWidgetData<String>(key, null);
    }
  }

  @override
  Future<bool> hasWidgets() async =>
      (await HomeWidget.getInstalledWidgets()).isNotEmpty;

  @override
  Stream<void> get taps => HomeWidget.widgetClicked;

  @override
  Future<bool> launchedFromWidget() async =>
      await HomeWidget.initiallyLaunchedFromHomeWidget() != null;
}
