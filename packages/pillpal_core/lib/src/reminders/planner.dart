import '../schedule/engine.dart';
import '../schedule/local_date.dart';
import 'notification_id.dart';
import 'notification_request.dart';
import 'reminder_source.dart';

/// iOS keeps at most this many pending local notifications per app.
const int iosPendingNotificationLimit = 64;

/// Default Android budget: below AlarmManager's 500 alarms per app.
const int androidDefaultNotificationBudget = 400;

/// How far ahead a plan reaches by default.
const Duration defaultReminderHorizon = Duration(hours: 48);

/// The longest allowed horizon.
const Duration maxReminderHorizon = Duration(days: 30);

/// Length of `YYYY-MM-DDTHH:MM` at the end of an occurrence key.
const int _keySuffixLength = 16;
const int _keyDateLength = 10;

/// Turns schedules and dose marks into the local notifications to keep
/// pending. Pure and deterministic; see docs/spec/reminders.md.
class ReminderPlanner {
  /// Creates a planner returning at most [budget] notifications that fire
  /// within [horizon]. [idMask] narrows the id space and exists for tests.
  const ReminderPlanner({
    required this.budget,
    this.horizon = defaultReminderHorizon,
    this.idMask = plannerIdMask,
  });

  /// Maximum number of returned notifications (spec §5).
  final int budget;

  /// Only notifications firing before `now + horizon` are planned.
  final Duration horizon;

  /// Notification ids are in `1..idMask`.
  final int idMask;

  /// Plans the notifications for [now] (docs/spec/reminders.md).
  ///
  /// [deviceTz] is used for [TzMode.local] sources. [handledKeys] holds the
  /// occurrence keys marked taken or skipped; [snoozedUntil] maps occurrence
  /// keys to the instant they are snoozed until. [retained] are the
  /// unsettled requests already applied to the platform: their ids are
  /// reserved and a request with the same identity keeps its id (spec §7).
  /// Throws [ArgumentError] for an invalid budget or horizon, or duplicate
  /// schedule ids.
  ReminderPlan plan({
    required DateTime now,
    required String deviceTz,
    required List<ReminderSource> sources,
    Set<String> handledKeys = const <String>{},
    Map<String, DateTime> snoozedUntil = const <String, DateTime>{},
    Iterable<NotificationRequest> retained = const <NotificationRequest>[],
  }) {
    _validate(sources);
    final window = _Window(now.toUtc(), horizon);
    final enabled = [
      for (final source in sources)
        if (source.enabled) source,
    ];
    final candidates = <_Candidate>[];
    final unplannable = <String>[];
    // A snoozed occurrence gets its snooze series instead (spec §3).
    final skip = {...handledKeys, ...snoozedUntil.keys};
    for (final source in enabled) {
      final occurrences = _expandSource(source, deviceTz, window);
      if (occurrences == null) {
        unplannable.add(source.scheduleId);
        continue;
      }
      _addRegularSeries(candidates, source, occurrences, skip, window);
    }
    final bySchedule = {for (final s in enabled) s.scheduleId: s};
    for (final MapEntry(:key, value: until) in snoozedUntil.entries) {
      final source = _sourceOfOccurrence(key, bySchedule);
      if (source != null && !handledKeys.contains(key)) {
        final startUs = until.microsecondsSinceEpoch;
        _addSeries(candidates, source, key, startUs, window, isSnooze: true);
      }
    }
    candidates.sort(_compareCandidates);
    unplannable.sort();
    return _select(candidates, window, unplannable, retained);
  }

  void _validate(List<ReminderSource> sources) {
    if (budget < 0 || budget > idMask) {
      throw RangeError.range(budget, 0, idMask, 'budget');
    }
    if (horizon <= Duration.zero || horizon > maxReminderHorizon) {
      throw ArgumentError.value(horizon, 'horizon', 'Must be in (0, 30 days]');
    }
    final ids = <String>{};
    for (final source in sources) {
      if (!ids.add(source.scheduleId)) {
        throw ArgumentError('Duplicate scheduleId in sources');
      }
    }
  }

  ReminderPlan _select(
    List<_Candidate> candidates,
    _Window window,
    List<String> unplannable,
    Iterable<NotificationRequest> retained,
  ) {
    final kept = candidates.length < budget ? candidates.length : budget;
    final allocator = NotificationIdAllocator(
      idMask: idMask,
      reserved: [for (final request in retained) request.id],
    );
    final owned = {for (final r in retained) _identityOf(r): r.id};
    final requests = <NotificationRequest>[];
    for (final candidate in candidates.take(kept)) {
      final input = candidate.idInput;
      final own = owned[input];
      final id = own != null && allocator.claim(own)
          ? own
          : allocator.allocate(input);
      requests.add(candidate.toRequest(id));
    }
    final replanBeforeUs =
        kept < candidates.length ? candidates[kept].fireAtUs : window.endUs;
    return ReminderPlan(
      requests: List<NotificationRequest>.unmodifiable(requests),
      replanBefore: _instant(replanBeforeUs),
      droppedByBudget: candidates.length - kept,
      unplannableScheduleIds: List<String>.unmodifiable(unplannable),
    );
  }
}

/// `now` and `now + horizon` in microseconds since the epoch.
class _Window {
  _Window(DateTime now, Duration horizon)
      : nowUs = now.microsecondsSinceEpoch,
        endUs = now.add(horizon).microsecondsSinceEpoch;

  final int nowUs;
  final int endUs;
}

/// One notification that may be planned, before budget and id assignment.
class _Candidate {
  _Candidate(
    this.source,
    this.occurrenceKey,
    this.fireAtUs,
    this.repeatIndex, {
    required this.isSnooze,
  });

  final ReminderSource source;
  final String occurrenceKey;
  final int fireAtUs;
  final int repeatIndex;
  final bool isSnooze;

  String get idInput =>
      notificationIdInput(occurrenceKey, repeatIndex, isSnooze: isSnooze);

  NotificationRequest toRequest(int id) => NotificationRequest(
        id: id,
        occurrenceKey: occurrenceKey,
        medicationId: source.medicationId,
        scheduleId: source.scheduleId,
        fireAtUtc: _instant(fireAtUs),
        repeatIndex: repeatIndex,
        level: source.level,
        isSnooze: isSnooze,
      );
}

/// The id input of an existing request: its identity across plans.
String _identityOf(NotificationRequest request) => notificationIdInput(
      request.occurrenceKey,
      request.repeatIndex,
      isSnooze: request.isSnooze,
    );

DateTime _instant(int microseconds) =>
    DateTime.fromMicrosecondsSinceEpoch(microseconds, isUtc: true);

/// Spec §5: fire time, first notifications before repeats, key, index.
int _compareCandidates(_Candidate a, _Candidate b) {
  final byTime = a.fireAtUs.compareTo(b.fireAtUs);
  if (byTime != 0) {
    return byTime;
  }
  final byTier = (a.repeatIndex == 0 ? 0 : 1) - (b.repeatIndex == 0 ? 0 : 1);
  if (byTier != 0) {
    return byTier;
  }
  final byKey = a.occurrenceKey.compareTo(b.occurrenceKey);
  return byKey != 0 ? byKey : a.repeatIndex.compareTo(b.repeatIndex);
}

/// Occurrences in `[now - repeat span, now + horizon)`, or null if the
/// effective zone is unknown (spec §1.1, §2).
List<Occurrence>? _expandSource(
  ReminderSource source,
  String deviceTz,
  _Window window,
) {
  final spanMinutes = source.repeatEveryMinutes * source.effectiveRepeats;
  final spanUs = spanMinutes * Duration.microsecondsPerMinute;
  try {
    return expand(
      source.rule,
      scheduleId: source.scheduleId,
      tz: source.effectiveTz(deviceTz),
      start: _instant(window.nowUs - spanUs),
      end: _instant(window.endUs),
    );
  } on ArgumentError {
    // Everything else expand validates is guaranteed by the planner, so this
    // is an unknown IANA zone: report it instead of failing every source.
    return null;
  }
}

/// Spec §2: regular series, repeats cut at the next occurrence.
void _addRegularSeries(
  List<_Candidate> out,
  ReminderSource source,
  List<Occurrence> occurrences,
  Set<String> skip,
  _Window window,
) {
  for (var i = 0; i < occurrences.length; i++) {
    final occurrence = occurrences[i];
    if (skip.contains(occurrence.key)) {
      continue;
    }
    final next = i + 1 < occurrences.length ? occurrences[i + 1] : null;
    _addSeries(
      out,
      source,
      occurrence.key,
      occurrence.atUtc.microsecondsSinceEpoch,
      window,
      isSnooze: false,
      repeatCutoffUs: next?.atUtc.microsecondsSinceEpoch,
    );
  }
}

/// Adds the fire times `start + k·N` (k = 0..M) that pass spec §4.
void _addSeries(
  List<_Candidate> out,
  ReminderSource source,
  String key,
  int startUs,
  _Window window, {
  required bool isSnooze,
  int? repeatCutoffUs,
}) {
  final stepUs = source.repeatEveryMinutes * Duration.microsecondsPerMinute;
  for (var k = 0; k <= source.effectiveRepeats; k++) {
    final fireAtUs = startUs + k * stepUs;
    final cut = k > 0 && repeatCutoffUs != null && fireAtUs >= repeatCutoffUs;
    if (fireAtUs >= window.endUs || cut) {
      return;
    }
    if (fireAtUs > window.nowUs) {
      out.add(_Candidate(source, key, fireAtUs, k, isSnooze: isSnooze));
    }
  }
}

/// The enabled source that [key] is a real occurrence of, or null when the
/// snooze entry is stale (spec §3.1).
ReminderSource? _sourceOfOccurrence(
  String key,
  Map<String, ReminderSource> bySchedule,
) {
  final separator = key.length - _keySuffixLength - 1;
  if (separator < 1 || key[separator] != '/') {
    return null;
  }
  final source = bySchedule[key.substring(0, separator)];
  final suffix = key.substring(separator + 1);
  final date = LocalDate.tryParse(suffix.substring(0, _keyDateLength));
  if (source == null || date == null || suffix[_keyDateLength] != 'T') {
    return null;
  }
  final time = suffix.substring(_keyDateLength + 1);
  final rule = source.rule;
  final hasSlot = rule.times.any((slot) => slot.time == time);
  return hasSlot && rule.occursOn(date) ? source : null;
}
