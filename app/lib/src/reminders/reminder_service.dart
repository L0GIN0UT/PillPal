import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:pillpal_core/pillpal_core.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../l10n/gen/app_localizations.dart';
import '../data/clock.dart';
import '../data/db/database.dart';
import 'applied_notification_store.dart';
import 'fingerprints.dart';
import 'notification_scheduler.dart';
import 'reminder_content.dart';
import 'reminder_inputs.dart';
import 'reminder_payload.dart';

/// The device's IANA zone, or null when unknown.
typedef TimeZoneSource = Future<String?> Function();

/// The locale notifications are rendered in.
typedef LocaleSource = Locale Function();

/// Applied notifications are kept at least this long after they fired.
const Duration minimumRetention = Duration(days: 2);

/// Outcome of the latest re-plan, for banners on the Today screen.
@immutable
class ReminderStatus {
  /// Creates a status.
  const ReminderStatus({
    this.plannedAt,
    this.planned = 0,
    this.droppedByBudget = 0,
    this.unplannableScheduleIds = const [],
    this.replanBefore,
    this.permissions = ReminderPermissions.unknown,
    this.exactAlarms = true,
    this.timeZone,
    this.failed = false,
  });

  /// When the latest successful re-plan ran; null before the first one.
  final DateTime? plannedAt;

  /// Notifications in the current plan.
  final int planned;

  /// Notifications left out by the budget (iOS 64 limit): later reminders
  /// exist only if the app runs again before [replanBefore].
  final int droppedByBudget;

  /// Schedules whose zone is unknown (not reminded).
  final List<String> unplannableScheduleIds;

  /// The plan must be refreshed before this instant.
  final DateTime? replanBefore;

  /// Permissions seen by the latest re-plan.
  final ReminderPermissions permissions;

  /// Whether exact alarms were used.
  final bool exactAlarms;

  /// The zone `local` schedules were planned in.
  final String? timeZone;

  /// Whether the latest re-plan failed (details are not kept: they may
  /// contain medical data).
  final bool failed;
}

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
  })  : _scheduler = scheduler,
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
  Future<ReminderStatus>? _current;
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
    final rendered = _render(plan, inputs, exact: exact);
    final next = [for (final item in rendered) item.applied];
    final diff = reconcile(retained, next, now: now);
    await _cancel(diff.cancelIds);
    final extra = await _checkPending(retained, rendered, diff, now);
    await _schedule([...diff.schedule.map((a) => a.id), ...extra], rendered);
    final nextIds = {for (final applied in next) applied.id};
    await _store.forget(diff.cancelIds.where((id) => !nextIds.contains(id)));
    await _store.upsert(next);
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

  List<_Rendered> _render(
    ReminderPlan plan,
    ReminderInputs inputs, {
    required bool exact,
  }) {
    final locale = reminderLocale(_locale());
    final strings = lookupAppLocalizations(locale);
    final actions = ReminderActionTitles(
      taken: strings.reminderActionTaken,
      snooze: strings.reminderActionSnooze,
      skip: strings.reminderActionSkip,
    );
    final rendered = <_Rendered>[];
    for (final request in plan.requests) {
      // Every request comes from one of the targets.
      final target = inputs.targets[request.scheduleId];
      if (target == null) {
        continue;
      }
      final content = reminderContent(strings, target, request);
      rendered.add(
        _Rendered(
          AppliedNotification(
            request,
            displayFingerprint: displayFingerprint(
              level: request.level,
              exact: exact,
              privacy: target.privacy,
              locale: locale.toLanguageTag(),
              title: content.title,
              body: content.body,
            ),
            scheduleFingerprint: target.scheduleFingerprint,
          ),
          _reminder(request, content, actions, exact: exact),
        ),
      );
    }
    return rendered;
  }

  ScheduledReminder _reminder(
    NotificationRequest request,
    ReminderContent content,
    ReminderActionTitles actions, {
    required bool exact,
  }) {
    return ScheduledReminder(
      id: request.id,
      fireAtUtc: request.fireAtUtc,
      level: request.level,
      exact: exact,
      title: content.title,
      body: content.body,
      payload: ReminderPayload(
        occurrenceKey: request.occurrenceKey,
        medicationId: request.medicationId,
      ).encode(),
      threadId: occurrenceThreadId(request.occurrenceKey),
      actions: actions,
    );
  }

  /// Consistency check against the platform (ADR §3): unknown pending ids
  /// in the planner range are cancelled; future planned notifications the
  /// platform lost (e.g. dropped on boot) are returned for rescheduling.
  Future<List<int>> _checkPending(
    List<AppliedNotification> retained,
    List<_Rendered> rendered,
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
            !pending.contains(item.applied.id) &&
            item.applied.request.fireAtUtc.isAfter(now))
          item.applied.id,
    ];
  }

  Future<void> _schedule(List<int> ids, List<_Rendered> rendered) async {
    final byId = {for (final item in rendered) item.applied.id: item.reminder};
    for (final id in ids) {
      final reminder = byId[id];
      // Re-checked right before the call: the platform rejects past times.
      if (reminder == null || !reminder.fireAtUtc.isAfter(_clock())) {
        continue;
      }
      try {
        await _scheduler.schedule(reminder);
      } on ArgumentError {
        // Its time passed during the re-plan; it stays retained as fired.
      }
    }
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

/// An applied notification with the reminder handed to the platform.
class _Rendered {
  _Rendered(this.applied, this.reminder);

  final AppliedNotification applied;
  final ScheduledReminder reminder;
}
