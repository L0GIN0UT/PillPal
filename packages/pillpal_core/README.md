# pillpal_core

Pure Dart (no Flutter) core of PillPal: the **schedule engine** —
validation of schedule rules and expansion into occurrences — used by the
mobile app for offline reminders and the "Today" screen, and the **reminder
planner** that derives local notifications from it.

It is the Dart twin of the Python reference implementation in
`backend/app/domain/schedule`. Both follow
[`docs/spec/schedule.md`](../../docs/spec/schedule.md) and both run the shared
vectors in [`spec/schedule-vectors/`](../../spec/schedule-vectors/), so the
client and the server compute the same occurrence keys and instants.

## Usage

```dart
import 'package:pillpal_core/pillpal_core.dart';

final rule = ScheduleRule.fromJson(jsonDecode(ruleJson)); // RuleValidationError
final occurrences = expand(
  rule,
  scheduleId: schedule.id,
  tz: 'Europe/Samara', // effective zone: device zone or the medication's fixed_tz
  start: DateTime.now(),
  end: DateTime.now().add(const Duration(days: 2)),
);
for (final o in occurrences) {
  print('${o.key} at ${o.atUtc}: ${o.doseAmount} ${o.doseUnit}');
}
```

- `occurrenceKey(scheduleId, localDate, localTime)` builds
  `"{scheduleId}/{YYYY-MM-DD}T{HH:MM}"` from the nominal local date and time.
- `localToUtc(date, hour, minute, tz)` resolves one wall time: a DST gap is
  read with the offset before the transition (02:30 in a 02:00→03:00 gap
  becomes 03:30 on the clock); an ambiguous time maps to the earlier instant.
- Caller errors (empty schedule id, `end` before `start`, window longer than
  400 days, unknown zone) throw `ArgumentError`.

The IANA database of `package:timezone` (`latest_all`) is loaded lazily on
first use; call `ensureTimeZonesInitialized()` at start-up to pay that cost
early. The engine computes offsets itself (it does not rely on
`TZDateTime`'s handling of non-existent times). Note that the `timezone`
database has no transitions after 2037, so instants for later dates may differ
from the server; keys never do.

## Reminder planner

`ReminderPlanner` turns schedules plus dose marks into the local notifications
the app keeps pending (spec: [`docs/spec/reminders.md`](../../docs/spec/reminders.md)).
It is pure and deterministic; ids are stable (FNV-1a of
`"{occurrenceKey}#{repeatIndex}"`), so re-planning is idempotent.

```dart
final now = clock.now();
final plan = const ReminderPlanner(budget: iosPendingNotificationLimit).plan(
  now: now,
  deviceTz: deviceZone,          // used by TzMode.local sources
  sources: sources,              // one ReminderSource per schedule
  handledKeys: takenOrSkipped,   // occurrence keys
  snoozedUntil: snoozes,         // occurrence key -> instant
);
final diff = reconcile(previouslyScheduled, plan.requests, now: now);
// cancel diff.cancelIds, schedule diff.schedule, re-plan before plan.replanBefore
```

## Development

```sh
dart pub get
dart format --set-exit-if-changed .
dart analyze --fatal-infos
dart test
```

`test/vectors_test.dart` reads `../../spec/schedule-vectors/*.json`, so run
the tests from this directory inside the monorepo.
