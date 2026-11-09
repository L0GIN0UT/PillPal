/// Pure Dart core of PillPal: domain models, the schedule engine, the dose
/// state and the reminder planner.
///
/// The schedule engine mirrors the Python reference implementation in
/// `backend/app/domain/schedule`; both are checked against the shared vectors
/// in `spec/schedule-vectors`. Specification: `docs/spec/schedule.md`.
/// The dose state (effective mark, snooze, due, missed) mirrors
/// `backend/app/domain/dose_state.py`; both are checked against
/// `spec/dose-state-vectors`. Specification: `docs/spec/dose-state.md`.
/// The GTIN / GS1 helpers (`docs/spec/gtin.md`) mirror
/// `catalog/catalog/domain` and are checked against `spec/gtin-vectors`.
/// The reminder planner (`docs/spec/reminders.md`) turns schedules into the
/// local notifications the app keeps pending.
library;

export 'src/catalog/gs1.dart';
export 'src/catalog/gtin.dart';
export 'src/doses/dose_event.dart';
export 'src/doses/occurrence_state.dart';
export 'src/reminders/notification_id.dart';
export 'src/reminders/notification_request.dart';
export 'src/reminders/planner.dart';
export 'src/reminders/reconcile.dart';
export 'src/reminders/reminder_source.dart';
export 'src/reminders/settle.dart';
export 'src/schedule/engine.dart';
export 'src/schedule/local_date.dart';
export 'src/schedule/rule.dart';
