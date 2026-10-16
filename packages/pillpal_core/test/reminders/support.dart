import 'package:pillpal_core/pillpal_core.dart';

/// Synthetic ids only (`.claude/rules/privacy.md` §9).
const String sid = '7f1c2d3e-0000-4000-8000-0000000000e2';
const String mid = '0b6c1a2e-0000-4000-8000-00000000000a';

/// Samara is UTC+4 all year: 08:00 = 04:00Z, 20:00 = 16:00Z.
const String samara = 'Europe/Samara';

/// docs/spec/reminders.md §10.
final DateTime now = DateTime.utc(2026, 10, 16, 5);

DateTime utc(int day, int hour, [int minute = 0]) =>
    DateTime.utc(2026, 10, day, hour, minute);

String key(String date, String time, {String scheduleId = sid}) =>
    '$scheduleId/${date}T$time';

ScheduleRule dailyRule(
  List<String> times, {
  String startDate = '2026-10-01',
}) {
  return ScheduleRule.fromJson(<String, Object?>{
    'v': 1,
    'kind': 'daily',
    'start_date': startDate,
    'times': [
      for (final time in times)
        {
          'time': time,
          'dose': {'amount': '1', 'unit': 'tablet'},
        },
    ],
  });
}

ReminderSource source({
  ScheduleRule? rule,
  ReminderLevel level = ReminderLevel.normal,
  String scheduleId = sid,
  String medicationId = mid,
  TzMode tzMode = TzMode.local,
  String? fixedTz,
  int every = 30,
  int repeats = 3,
  bool enabled = true,
}) {
  return ReminderSource(
    medicationId: medicationId,
    scheduleId: scheduleId,
    rule: rule ?? dailyRule(['08:00', '20:00']),
    level: level,
    tzMode: tzMode,
    fixedTz: fixedTz,
    repeatEveryMinutes: every,
    maxRepeats: repeats,
    enabled: enabled,
  );
}

ReminderPlan plan(
  List<ReminderSource> sources, {
  DateTime? at,
  String deviceTz = samara,
  int budget = androidDefaultNotificationBudget,
  Duration horizon = defaultReminderHorizon,
  Set<String> handled = const <String>{},
  Map<String, DateTime> snoozed = const <String, DateTime>{},
  int idMask = plannerIdMask,
  Iterable<NotificationRequest> retained = const <NotificationRequest>[],
}) {
  final planner = ReminderPlanner(
    budget: budget,
    horizon: horizon,
    idMask: idMask,
  );
  return planner.plan(
    now: at ?? now,
    deviceTz: deviceTz,
    sources: sources,
    handledKeys: handled,
    snoozedUntil: snoozed,
    retained: retained,
  );
}

/// `(occurrenceKey, repeatIndex, fireAtUtc)` of each request, for compact
/// expectations.
List<(String, int, DateTime)> fires(ReminderPlan plan) => [
      for (final request in plan.requests)
        (request.occurrenceKey, request.repeatIndex, request.fireAtUtc),
    ];
