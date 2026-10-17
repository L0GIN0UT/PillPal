import 'dart:async';
import 'dart:ui';

import 'package:drift/drift.dart' show TableUpdate, TableUpdateQuery;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../features/auth/auth_session.dart';
import '../reminders/reminder_content.dart';
import '../settings/app_settings.dart';
import 'alert_notification_sink.dart';
import 'push_need_provider.dart';
import 'push_payload.dart';
import 'push_providers.dart';

/// App-wide plumbing of relative alerts (milestone 3.9), above the router.
/// It asks the [PushService] to reconcile whenever the need may have
/// changed: at start, on sign-in and sign-out, on resume, after a successful
/// sync and when scopes or links are written (debounced). It also creates the
/// Android channel, and on iOS routes the taps on alerts.
class PushScope extends ConsumerStatefulWidget {
  /// Wraps [child].
  const PushScope({required this.child, super.key});

  /// How long writes may follow one another before one reconcile runs.
  static const Duration debounce = Duration(seconds: 1);

  /// The app.
  final Widget child;

  @override
  ConsumerState<PushScope> createState() => _PushScopeState();
}

class _PushScopeState extends ConsumerState<PushScope>
    with WidgetsBindingObserver {
  StreamSubscription<Set<TableUpdate>>? _updates;
  StreamSubscription<Map<String, String>>? _taps;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final db = ref.read(databaseProvider);
    _updates = db
        .tableUpdates(
          TableUpdateQuery.onAllTables([db.accessScopes, db.relativeLinks]),
        )
        .listen((_) => _reconcileSoon());
    unawaited(_prepareAndroidChannel());
    unawaited(_listenToIosTaps());
    unawaited(ref.read(pushServiceProvider).reconcile());
  }

  void _reconcileSoon() {
    _timer?.cancel();
    _timer = Timer(PushScope.debounce, _reconcileNow);
  }

  void _reconcileNow() {
    if (mounted) {
      unawaited(ref.read(pushServiceProvider).reconcile());
    }
  }

  /// The channel exists before the first alert arrives; the background
  /// isolate creates it as well (idempotent).
  Future<void> _prepareAndroidChannel() async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      final locale = ref.read(settingsProvider).locale ??
          PlatformDispatcher.instance.locale;
      await FlutterAlertNotificationSink(reminderStrings(locale)).prepare();
    } on Object {
      // The notification will create it on demand.
    }
  }

  Future<void> _listenToIosTaps() async {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    try {
      final channel = ref.read(apnsChannelProvider);
      _taps = channel.taps.listen(_openTap);
      final initial = await channel.initialTap();
      if (initial != null) {
        _openTap(initial);
      }
    } on Object {
      // A tap that cannot be routed just opens the app.
    }
  }

  void _openTap(Map<String, String> data) {
    final payload = PushPayload.tryParse(data);
    if (payload != null && mounted) {
      unawaited(ref.read(alertTapRouterProvider).open(payload));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _reconcileNow();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    unawaited(_updates?.cancel());
    unawaited(_taps?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      authSessionProvider.select((session) => session.valueOrNull),
      (previous, next) => _reconcileNow(),
    );
    ref.listen(pushRecheckProvider, (previous, next) => _reconcileSoon());
    ref.listen(
      syncStatusProvider.select((status) => status.lastSuccessAt),
      (previous, next) {
        if (next != null && next != previous) {
          _reconcileSoon();
        }
      },
    );
    return widget.child;
  }
}
