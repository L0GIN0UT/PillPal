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

/// First wait before retrying a failed re-plan; doubled after every
/// further failure up to [maximumRetryDelay].
const Duration firstRetryDelay = Duration(minutes: 1);

/// Longest wait between retries of a failing re-plan.
const Duration maximumRetryDelay = Duration(minutes: 30);

/// Wires the re-plan triggers of milestone 2.3 around a [ReminderService]
/// (ADR 0001 §9): app start and resume (permissions, time zone and locale
/// are re-read on every re-plan), every write to medications, schedules,
/// dose events, profiles, scopes (role, archive), the per-device profile
/// switch or reminder settings - local, pulled by sync or
/// recorded by a notification action - and `replanBefore`.
class ReminderController {
  /// Creates a controller. [platform] is null where the notification plugin
  /// is unavailable (tests); [onOpenToday] routes a tapped notification;
  /// [onAlertTap] routes the payload of a tapped relatives alert;
  /// [onSyncNeeded] pushes dose events recorded outside the main isolate;
  /// [onReplanned] runs after every re-plan (the home-screen widget follows
  /// the same triggers).
  ReminderController({
    required AppDatabase db,
    required ReminderService service,
    required Clock clock,
    required LocaleSource locale,
    required void Function() onOpenToday,
    required void Function() onSyncNeeded,
    Future<bool> Function(String? payload)? onAlertTap,
    FlutterNotificationScheduler? platform,
    void Function()? onReplanned,
    this.debounce = const Duration(milliseconds: 300),
    this.retryDelay = firstRetryDelay,
  })  : _db = db,
        _service = service,
        _clock = clock,
        _locale = locale,
        _onOpenToday = onOpenToday,
        _onSyncNeeded = onSyncNeeded,
        _onAlertTap = onAlertTap,
        _onReplanned = onReplanned,
        _platform = platform;

  /// Writes closer together than this cause one re-plan.
  final Duration debounce;

  /// First wait before a failed re-plan is retried (then doubled).
  final Duration retryDelay;

  final AppDatabase _db;
  final ReminderService _service;
  final Clock _clock;
  final LocaleSource _locale;
  final void Function() _onOpenToday;
  final void Function() _onSyncNeeded;
  final Future<bool> Function(String? payload)? _onAlertTap;
  final void Function()? _onReplanned;
  final FlutterNotificationScheduler? _platform;
  StreamSubscription<Set<TableUpdate>>? _updates;
  StreamSubscription<String>? _scopeUpdates;
  StreamSubscription<ReminderStatus>? _statuses;
  ReceivePort? _port;
  Timer? _debounceTimer;
  Timer? _replanTimer;
  Timer? _retryTimer;
  Duration? _lastRetryDelay;
  bool _started = false;

  /// Initializes the plugin, subscribes to the triggers and re-plans.
  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    final platform = _platform;
    if (platform != null) {
      _listenToBackgroundActions();
      await _initialize(platform);
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
            _db.profileDeviceSettings,
          ]),
        )
        .listen((_) => requestReplan());
    // Scope rows are written on every pulled page (cursor, pull time): only
    // a change of role or archive state - or a scope coming or going -
    // concerns the reminders.
    _scopeUpdates = _db
        .select(_db.accessScopes)
        .watch()
        .map(_scopeSignature)
        .distinct()
        .skip(1)
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

  /// Re-plans now; a failure leaves the status `failed` (no details
  /// logged) and is retried with exponential backoff until a re-plan
  /// succeeds.
  Future<void> replanNow() async {
    bool failed;
    try {
      failed = (await _service.replan()).failed;
    } on Object {
      failed = true;
    }
    _armRetryTimer(failed: failed);
    _onReplanned?.call();
  }

  /// Stops listening (the scheduled notifications stay).
  Future<void> stop() async {
    _debounceTimer?.cancel();
    _replanTimer?.cancel();
    _retryTimer?.cancel();
    await _updates?.cancel();
    await _scopeUpdates?.cancel();
    await _statuses?.cancel();
    final port = _port;
    if (port != null) {
      IsolateNameServer.removePortNameMapping(reminderEventsPortName);
      port.close();
    }
    _started = false;
  }

  static String _scopeSignature(List<AccessScopeRow> rows) {
    final parts = [
      for (final row in rows) '${row.profileId}:${row.role}:${row.archived}',
    ]..sort();
    return parts.join(',');
  }

  /// Initializes the plugin and routes a launching notification. A plugin
  /// failure must not stop the re-plan triggers: scheduling may still work
  /// and the status reports what does not. Nothing is logged.
  Future<void> _initialize(FlutterNotificationScheduler platform) async {
    try {
      await platform.initialize(
        strings: reminderStrings(_locale()),
        onResponse: _onResponse,
        onBackground: onBackgroundNotificationResponse,
      );
      final launch = await platform.launchResponse();
      if (launch != null) {
        _onResponse(launch);
      }
    } on Object {
      // Intentionally silent, see above.
    }
  }

  void _armRetryTimer({required bool failed}) {
    _retryTimer?.cancel();
    final last = _lastRetryDelay;
    if (!failed || !_started) {
      _lastRetryDelay = null;
      return;
    }
    final delay = last == null
        ? retryDelay
        : (last * 2 > maximumRetryDelay ? maximumRetryDelay : last * 2);
    _lastRetryDelay = delay;
    _retryTimer = Timer(delay, () => unawaited(replanNow()));
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
    } else {
      // A tapped alert about a relative (milestone 3.9): same plugin, other
      // payload; the callback ignores anything that is not one.
      unawaited(_onAlertTap?.call(response.payload));
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
  /// isolate's streams; it says so through a port, and this isolate answers
  /// so that the background one leaves the re-plan to it (the table update
  /// below triggers it).
  void _listenToBackgroundActions() {
    final port = ReceivePort();
    IsolateNameServer.removePortNameMapping(reminderEventsPortName);
    IsolateNameServer.registerPortWithName(
      port.sendPort,
      reminderEventsPortName,
    );
    port.listen(
      (message) => answerBackgroundMessage(message, () {
        _db.notifyUpdates({
          TableUpdate.onTable(_db.doseEvents, kind: UpdateKind.insert),
        });
        _onSyncNeeded();
      }),
    );
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
