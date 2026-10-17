import 'dart:async';

import '../routing/routes.dart';
import 'push_payload.dart';

/// Routes a tapped relatives alert (ADR 0008 §2): a dose alert opens the
/// relative's day, a link push opens Family. A profile the device does not
/// know yet (the alert beat the sync) opens Family and starts a refresh, so
/// the relative appears without another tap.
class AlertTapRouter {
  /// Creates the router. [push] and [go] are the router's navigation.
  AlertTapRouter({
    required Future<bool> Function(String profileId) knowsProfile,
    required void Function(String location) push,
    required void Function(String location) go,
    required Future<void> Function() refresh,
  })  : _knowsProfile = knowsProfile,
        _push = push,
        _go = go,
        _refresh = refresh;

  final Future<bool> Function(String profileId) _knowsProfile;
  final void Function(String location) _push;
  final void Function(String location) _go;
  final Future<void> Function() _refresh;

  /// Opens the destination of [payload].
  Future<void> open(PushPayload payload) async {
    if (payload.kind.isDoseAlert && await _knowsProfile(payload.profileId)) {
      _push(AppRoutes.profileToday(payload.profileId));
      return;
    }
    _go(AppRoutes.family);
    try {
      await _refresh();
    } on Object {
      // Offline: Family shows what is stored; the next sync catches up.
    }
  }

  /// Opens the destination of a local notification's [payload]; false when
  /// it is not an alert of this app (a dose reminder, or garbage).
  Future<bool> openFromPayload(String? payload) async {
    final parsed = PushPayload.tryDecode(payload);
    if (parsed == null) {
      return false;
    }
    await open(parsed);
    return true;
  }
}
