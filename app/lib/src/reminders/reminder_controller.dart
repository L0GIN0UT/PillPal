import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:drift/drift.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../data/clock.dart';
import '../data/db/database.dart';
import 'background_handler.dart';
import 'flutter_notification_scheduler.dart';
import 'reminder_actions.dart';
import 'reminder_content.dart';
import 'reminder_payload.dart';
import 'reminder_service.dart';

/// Shortest wait before a `replanBefore` re-plan.
const Duration _minimumReplanDelay = Duration(minutes: 1);

/// Wires the re-plan triggers of milestone 2.3 around a [ReminderService]
/// (ADR 0001 §9): app start and resume (permissions, time zone and locale
/// are re-read on every re-plan), every write to medications, schedules,
/// dose events, profiles or reminder settings - local, pulled by sync or
/// recorded by a notification action - and `replanBefore`.
class ReminderController {
  /// Creates a controller. [platform] is null where the notification plugin
  /// is unavailable (tests); [onOpenToday] routes a tapped notification;
  /// [onSyncNeeded] pushes dose events recorded outside the main isolate.
  ReminderController({
    required AppDatabase db,
    required ReminderService service,
    required Clock clock,
    required LocaleSource locale,
    required void Function() onOpenToday,
    required void Function() onSyncNeeded,
    FlutterNotificationScheduler? platform,
    this.debounce = const Duration(milliseconds: 300),
  })  : _db = db,
        _service = service,
        _clock = clock,
        _locale = locale,
        _onOpenToday = onOpenToday,
        _onSyncNeeded = onSyncNeeded,
        _platform = platform;

  /// Writes closer together than this cause one re-plan.
  final Duration debounce;

  final AppDatabase _db;
  final ReminderService _service;
  final Clock _clock;
  final LocaleSource _locale;
  final void Function() _onOpenToday;
  final void Function() _onSyncNeeded;
  final FlutterNotificationScheduler? _platform;
  StreamSubscription<Set<TableUpdate>>? _updates;
  StreamSubscription<ReminderStatus>? _statuses;
  ReceivePort? _port;
  Timer? _debounceTimer;
  Timer? _replanTimer;
  bool _started = false;

  /// Initializes the plugin, subscribes to the triggers and re-plans.
  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    final platform = _platform;
    if (platform != null) {
      await platform.initialize(
        strings: reminderStrings(_locale()),
        onResponse: _onResponse,
        onBackground: onBackgroundNotificationResponse,
      );
      _listenToBackgroundActions();
      final launch = await platform.launchResponse();
      if (launch != null) {
        _onResponse(launch);
      }
    }
    _updates = _db
        .tableUpdates(
          TableUpdateQuery.onAllTables([
            _db.profiles,
            _db.medications,
            _db.schedules,
            _db.doseEvents,
            _db.reminderDefaults,
            _db.medicationReminderSettings,
          ]),
        )
        .listen((_) => requestReplan());
    _statuses = _service.statusChanges.listen(_armReplanTimer);
    await replanNow();
  }

  /// The app came to the foreground: permissions, zone or locale may have
  /// changed in the system settings.
  Future<void> onResume() => replanNow();

  /// Re-plans after [debounce]; repeated requests restart the wait.
  void requestReplan() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(debounce, () => unawaited(replanNow()));
  }

  /// Re-plans now; failures leave the status `failed` (no details logged).
  Future<void> replanNow() async {
    try {
      await _service.replan();
    } on Object {
      // Reported through ReminderStatus.failed.
    }
  }

  /// Stops listening (the scheduled notifications stay).
  Future<void> stop() async {
    _debounceTimer?.cancel();
    _replanTimer?.cancel();
    await _updates?.cancel();
    await _statuses?.cancel();
    final port = _port;
    if (port != null) {
      IsolateNameServer.removePortNameMapping(reminderEventsPortName);
      port.close();
    }
    _started = false;
  }

  /// A foreground notification response: a tap opens Today; an action
  /// (platforms that deliver it here) is recorded like in the background.
  void _onResponse(NotificationResponse response) {
    final action = ReminderAction.fromResponse(
      actionId: response.actionId,
      payload: response.payload,
    );
    if (action != null) {
      unawaited(_record(action));
    } else if (ReminderPayload.tryDecode(response.payload) != null) {
      _onOpenToday();
    }
  }

  Future<void> _record(ReminderAction action) async {
    try {
      await ReminderActionHandler(db: _db, clock: _clock, newId: newUuid)
          .handle(action);
      _onSyncNeeded();
    } on Object {
      // Nothing is logged (medical data); the dose stays unmarked.
    }
  }

  /// Dose events written by the background isolate do not reach this
  /// isolate's streams; it says so through a port.
  void _listenToBackgroundActions() {
    final port = ReceivePort();
    IsolateNameServer.removePortNameMapping(reminderEventsPortName);
    IsolateNameServer.registerPortWithName(
      port.sendPort,
      reminderEventsPortName,
    );
    port.listen((_) {
      _db.notifyUpdates({
        TableUpdate.onTable(_db.doseEvents, kind: UpdateKind.insert),
      });
      _onSyncNeeded();
    });
    _port = port;
  }

  void _armReplanTimer(ReminderStatus status) {
    final before = status.replanBefore;
    _replanTimer?.cancel();
    if (before == null) {
      return;
    }
    var delay = before.difference(_clock()) - _minimumReplanDelay;
    if (delay < _minimumReplanDelay) {
      delay = _minimumReplanDelay;
    }
    _replanTimer = Timer(delay, () => unawaited(replanNow()));
  }
}
