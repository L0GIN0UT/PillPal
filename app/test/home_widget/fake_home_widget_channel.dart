import 'dart:async';

import 'package:pillpal/src/home_widget/home_widget_channel.dart';

/// Records what the app writes to the home-screen widget.
class FakeHomeWidgetChannel implements HomeWidgetChannel {
  /// Creates the fake.
  FakeHomeWidgetChannel({
    this.supported = true,
    this.installed = true,
    this.launched = false,
  });

  /// See [HomeWidgetChannel.isSupported].
  final bool supported;

  /// See [HomeWidgetChannel.hasWidgets].
  bool installed;

  /// See [HomeWidgetChannel.launchedFromWidget].
  final bool launched;

  /// The stored widget data.
  final Map<String, String> stored = {};

  /// Redraw requests.
  int redraws = 0;

  final StreamController<void> _taps = StreamController<void>.broadcast();

  /// Simulates a tap on the widget.
  void tap() => _taps.add(null);

  @override
  bool get isSupported => supported;

  @override
  Future<void> save(Map<String, String> data) async => stored.addAll(data);

  @override
  Future<void> remove(List<String> keys) async => keys.forEach(stored.remove);

  @override
  Future<bool> hasWidgets() async => installed;

  @override
  Future<void> redraw() async => redraws++;

  @override
  Stream<void> get taps => _taps.stream;

  @override
  Future<bool> launchedFromWidget() async => launched;
}
