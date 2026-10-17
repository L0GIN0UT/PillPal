import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import '../features/auth/auth_session.dart';
import '../features/common/local_time.dart';
import 'providers.dart';

/// Starts the reminder triggers for the app's lifetime and re-plans on
/// resume and on language changes (ADR 0001 §9). On start and resume it also
/// tells the server the device's time zone (the own `self` profile follows
/// the phone, D4). Wraps the app in `main.dart`; widget tests pump the app
/// without it.
class ReminderScope extends ConsumerStatefulWidget {
  /// Wraps [child].
  const ReminderScope({required this.child, super.key});

  /// The app.
  final Widget child;

  @override
  ConsumerState<ReminderScope> createState() => _ReminderScopeState();
}

class _ReminderScopeState extends ConsumerState<ReminderScope>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(ref.read(reminderControllerProvider).start());
    unawaited(_syncDeviceZone());
    unawaited(_evictStaleScopes());
  }

  Future<void> _evictStaleScopes() async {
    try {
      await ref.read(syncEngineProvider).evictStaleScopes();
    } on Object {
      // Retried at the next start and at every sync.
    }
  }

  /// Best effort: a zone the engine does not know, or a missing profile,
  /// changes nothing (nothing is logged, the zone is not medical data but
  /// the failure carries none either).
  Future<void> _syncDeviceZone() async {
    try {
      final zone = await ref.read(timeZoneReaderProvider)();
      if (!mounted || zone == null || !isKnownTimeZone(zone)) {
        return;
      }
      final changed =
          await ref.read(profilesRepositoryProvider).syncDeviceZone(zone);
      if (changed && mounted) {
        requestSync(ref);
      }
    } on Object {
      // Retried at the next start or resume.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // A background engine (WorkManager flush) changes the outbox and the
      // dose events in its own connection; streams here do not see that.
      final db = ref.read(databaseProvider);
      db.markTablesUpdated({db.outbox, db.doseEvents});
      unawaited(ref.read(reminderControllerProvider).onResume());
      unawaited(_syncDeviceZone());
    }
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    ref.read(reminderControllerProvider).requestReplan();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<Locale>(
      reminderLocaleProvider,
      (previous, next) => ref.read(reminderControllerProvider).requestReplan(),
    );
    return widget.child;
  }
}
