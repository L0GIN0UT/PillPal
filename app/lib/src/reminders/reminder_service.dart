import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:pillpal_core/pillpal_core.dart';
import 'package:timezone/timezone.dart' as tz;

import '../data/clock.dart';
import '../data/db/database.dart';
import 'applied_notification_store.dart';
import 'notification_scheduler.dart';
import 'reminder_content.dart';
import 'reminder_inputs.dart';
import 'reminder_rendering.dart';
import 'reminder_status.dart';

export 'reminder_status.dart';

/// The device's IANA zone, or null when unknown.
typedef TimeZoneSource = Future<String?> Function();

/// The locale notifications are rendered in.
typedef LocaleSource = Locale Function();

/// Applied notifications are kept at least this long after they fired.
const Duration minimumRetention = Duration(days: 2);

/// Whether [name] is an IANA zone known to the engine's database.
bool isKnownTimeZone(String name) {
  ensureTimeZonesInitialized();
  try {
    tz.getLocation(name);
    return true;
  } on Object {
    return name == 'UTC';
  }
}

/// Keeps the platform's pending notifications equal to the reminder plan
/// (docs/spec/reminders.md, docs/adr/0001-local-notifications.md §9):
/// settle -> plan (with retained ids) -> reconcile -> cancel -> schedule ->
/// persist. Idempotent and cheap to call; concurrent calls are serialized
/// and coalesced.
class ReminderService {
  /// Creates the service.
  ReminderService({
    required AppDatabase db,
    required NotificationScheduler scheduler,
    required Clock clock,
    required TimeZoneSource deviceTimeZone,
    required LocaleSource locale,
    this.budget = androidDefaultNotificationBudget,
    this.horizon = defaultReminderHorizon,
    bool rearmOnFirstReplan = false,
  })  : _rearmPending = rearmOnFirstReplan,
        _scheduler = scheduler,
        _clock = clock,
        _deviceTimeZone = deviceTimeZone,
        _locale = locale,
        _loader = ReminderInputsLoader(db),
        _store = AppliedNotificationStore(db);

  /// Maximum number of planned notifications (iOS: 60, Android: 400).
  final int budget;

  /// How far ahead the plan reaches.
  final Duration horizon;

  final NotificationScheduler _scheduler;
  final Clock _clock;
  final TimeZoneSource _deviceTimeZone;
  final LocaleSource _locale;
  final ReminderInputsLoader _loader;
  final AppliedNotificationStore _store;
  final StreamController<ReminderStatus> _statusController =
      StreamController<ReminderStatus>.broadcast();
  ReminderStatus _status = const ReminderStatus();

  /// Android: the plugin answers `pendingNotificationRequests()` from its
  /// own cache, not from AlarmManager. After a force stop or an OEM kill the
  /// alarms are gone while the cache still lists them, so the first
  /// successful re-plan of a process schedules every future notification
  /// again (same ids, so it replaces in place; ADR 0001 §3).
  bool _rearmPending;
  Future<Object?>? _current;
  Future<ReminderStatus>? _queued;

  /// The latest status.
  ReminderStatus get status => _status;

  /// Status updates after every re-plan.
  Stream<ReminderStatus> get statusChanges => _statusController.stream;

  /// Brings the platform up to date. A call during a running re-plan runs
  /// once more after it (several such calls share that run). Throws what
  /// the re-plan threw; the status then reports `failed`.
  Future<ReminderStatus> replan() {
    final current = _current;
    if (current == null) {
      final run = _replanOnce().whenComplete(() => _current = null);
      _current = run;
      return run;
    }
    return _queued ??= current.then<void>((_) {}, onError: (Object _) {}).then(
      (_) {
        _queued = null;
        return replan();
      },
    );
  }

  /// Cancels every notification of the app - pending and in the tray - and
  /// forgets what was applied: the account's data is leaving the device
  /// (sign-out, another account signs in; ADR 0002 §1). Waits for a running
  /// re-plan, so none of its notifications survives.
  Future<void> clearAll() async {
    for (var running = _current; running != null; running = _current) {
      await running.then<void>((_) {}, onError: (Object _) {});
    }
    final run = _clearOnce();
    _current = run;
    try {
      await run;
    } finally {
      _current = null;
    }
  }

  Future<void> _clearOnce() async {
    await _scheduler.cancelAll();
    await _store.clear();
    _emit(ReminderStatus(permissions: _status.permissions));
  }

  /// Releases the status stream.
  Future<void> dispose() => _statusController.close();

  Future<ReminderStatus> _replanOnce() async {
    try {
      final permissions = await _scheduler.permissions();
      ReminderStatus status;
      try {
        status =
            await _apply(permissions, exact: permissions.exactAlarmsAllowed);
      } on ExactAlarmsNotPermitted {
        // Revoked since the check: re-apply everything inexact (ADR §4).
        status = await _apply(permissions, exact: false);
      }
      if (!status.failed) {
        _rearmPending = false;
      }
      _emit(status);
      return status;
    } on Object {
      _emit(
        ReminderStatus(
          plannedAt: _status.plannedAt,
          permissions: _status.permissions,
          failed: true,
        ),
      );
      rethrow;
    }
  }

  Future<ReminderStatus> _apply(
    ReminderPermissions permissions, {
    required bool exact,
  }) async {
    final now = _clock().toUtc();
    final inputs = await _loader.load(now);
    final deviceTz = await _timeZone(inputs.fallbackTimeZone);
    final retained = await _settle(inputs);
    final plan = ReminderPlanner(budget: budget, horizon: horizon).plan(
      now: now,
      deviceTz: deviceTz,
      sources: [for (final target in inputs.targets.values) target.source],
      handledKeys: inputs.states.handled,
      snoozedUntil: inputs.states.snoozedUntil,
      retained: [for (final applied in retained) applied.request],
    );
    final rendered = renderPlan(
      plan,
      inputs,
      locale: reminderLocale(_locale()),
      exact: exact,
    );
    final next = [for (final item in rendered) item.applied];
    final diff = reconcile(retained, next, now: now);
    await _cancel(diff.cancelIds);
    final extra = await _checkPending(retained, rendered, diff, now);
    final failed = await _schedule(
      [...diff.schedule.map((a) => a.id), ...extra],
      rendered,
    );
    final nextIds = {for (final applied in next) applied.id};
    await _store.forget(diff.cancelIds.where((id) => !nextIds.contains(id)));
    // A notification the platform refused is not recorded as applied, so
    // the next re-plan schedules it again (a previous row stays as it was).
    await _store.upsert(next.where((applied) => !failed.contains(applied.id)));
    await _store.forgetOlderThan(now.subtract(_retention(inputs)));
    return ReminderStatus(
      plannedAt: now,
      planned: next.length,
      droppedByBudget: plan.droppedByBudget,
      unplannableScheduleIds: plan.unplannableScheduleIds,
      replanBefore: plan.replanBefore,
      permissions: permissions,
      exactAlarms: exact,
      timeZone: deviceTz,
      timeSensitiveDegraded: !permissions.timeSensitiveAllowed &&
          plan.requests.any((request) => request.level.repeats),
      failed: failed.isNotEmpty,
    );
  }

  /// Cancels and forgets settled notifications; returns the rest.
  Future<List<AppliedNotification>> _settle(ReminderInputs inputs) async {
    final retained = await _store.all();
    final settled = settleIds(
      retained: retained,
      handledKeys: inputs.states.handled,
      snoozedKeys: inputs.states.snoozedUntil.keys.toSet(),
      liveSchedules: {
        for (final MapEntry(:key, :value) in inputs.targets.entries)
          key: value.scheduleFingerprint,
      },
    );
    await _cancel(settled);
    await _store.forget(settled);
    final gone = settled.toSet();
    return [
      for (final applied in retained)
        if (!gone.contains(applied.id)) applied,
    ];
  }

  /// Consistency check against the platform (ADR §3): unknown pending ids
  /// in the planner range are cancelled; future planned notifications the
  /// platform lost (e.g. dropped on boot) are returned for rescheduling -
  /// all future ones while [_rearmPending].
  Future<List<int>> _checkPending(
    List<AppliedNotification> retained,
    List<RenderedReminder> rendered,
    ReminderDiff diff,
    DateTime now,
  ) async {
    final pending = await _scheduler.pendingIds();
    final known = {
      for (final applied in retained) applied.id,
      for (final item in rendered) item.applied.id,
    };
    await _cancel([
      for (final id in pending)
        if (id >= 1 && id <= plannerIdMask && !known.contains(id)) id,
    ]);
    final scheduling = {for (final applied in diff.schedule) applied.id};
    return [
      for (final item in rendered)
        if (!scheduling.contains(item.applied.id) &&
            (_rearmPending || !pending.contains(item.applied.id)) &&
            item.applied.request.fireAtUtc.isAfter(now))
          item.applied.id,
    ];
  }

  /// Schedules [ids]; returns those the platform refused. One refused
  /// notification never stops the others (a medication reminder that does
  /// not fire is the worst bug); a refused exact alarm aborts the run so
  /// that it is re-applied inexact.
  Future<Set<int>> _schedule(
      List<int> ids, List<RenderedReminder> rendered) async {
    final byId = {for (final item in rendered) item.applied.id: item.reminder};
    final failed = <int>{};
    for (final id in ids) {
      final reminder = byId[id];
      // Re-checked right before the call: the platform rejects past times.
      if (reminder == null || !reminder.fireAtUtc.isAfter(_clock())) {
        continue;
      }
      try {
        await _scheduler.schedule(reminder);
      } on ExactAlarmsNotPermitted {
        rethrow;
      } on ArgumentError {
        // Its time passed during the re-plan; it stays retained as fired.
      } on Object {
        failed.add(id); // Not logged: errors may carry medical data.
      }
    }
    return failed;
  }

  Future<void> _cancel(Iterable<int> ids) async {
    for (final id in ids) {
      await _scheduler.cancel(id);
    }
  }

  Future<String> _timeZone(String? fallback) async {
    String? device;
    try {
      device = await _deviceTimeZone();
    } on Object {
      device = null;
    }
    for (final candidate in [device, fallback]) {
      if (candidate != null && isKnownTimeZone(candidate)) {
        return candidate;
      }
    }
    return 'UTC';
  }

  /// At least [minimumRetention] and the longest repeat span (spec §8).
  Duration _retention(ReminderInputs inputs) {
    var minutes = minimumRetention.inMinutes;
    for (final target in inputs.targets.values) {
      final source = target.source;
      minutes = math.max(
        minutes,
        source.repeatEveryMinutes * source.effectiveRepeats,
      );
    }
    return Duration(minutes: minutes);
  }

  void _emit(ReminderStatus status) {
    _status = status;
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }
}
