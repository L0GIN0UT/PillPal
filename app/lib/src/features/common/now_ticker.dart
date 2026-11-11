import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../doses/dose_status.dart';
import 'local_time.dart';

/// Re-reads [nowProvider] every [DoseTiming.refreshEvery] so what depends on
/// the time alone (a dose turning "missed") stays right without any event.
///
/// One timer for the whole app: Today and the Family tab each [attach] while
/// mounted, and the timer runs while at least one is. It ticks only while
/// the app is in the foreground: it stops on hidden/paused and the clock is
/// re-read once on resume. The tabs of the shell stay mounted, so it does not
/// follow which tab is visible (one cheap tick a minute, no extra timers).
///
/// Screens attach in `initState` and detach in `dispose` (not a watched
/// provider: the timer must stop synchronously with the widget).
final nowTickerProvider = Provider<NowTicker>((ref) {
  final ticker = NowTicker(() => ref.invalidate(nowProvider));
  ref.onDispose(ticker.shutDown);
  return ticker;
});

/// The shared ticker behind [nowProvider]; see [nowTickerProvider].
class NowTicker {
  /// Creates a ticker that calls [tick] once a minute while it runs.
  NowTicker(this._tick);

  final VoidCallback _tick;
  int _users = 0;
  Timer? _timer;
  AppLifecycleListener? _lifecycle;

  /// A screen that shows time-dependent state is on screen.
  void attach() {
    _users++;
    if (_users == 1) {
      _lifecycle = AppLifecycleListener(
        onResume: () {
          _tick();
          _start();
        },
        onHide: _stop,
        onPause: _stop,
      );
      _start();
    }
  }

  /// The screen went away; the last one stops the timer.
  void detach() {
    if (_users > 0 && --_users == 0) {
      shutDown();
    }
  }

  /// Stops everything (the last screen left, or the container is disposed).
  void shutDown() {
    _stop();
    _lifecycle?.dispose();
    _lifecycle = null;
  }

  void _start() {
    _timer ??= Timer.periodic(DoseTiming.refreshEvery, (_) => _tick());
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }
}
