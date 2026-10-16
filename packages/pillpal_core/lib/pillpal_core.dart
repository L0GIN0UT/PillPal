/// Pure Dart core of PillPal: domain models and the schedule engine.
///
/// The schedule engine mirrors the Python reference implementation in
/// `backend/app/domain/schedule`; both are checked against the shared vectors
/// in `spec/schedule-vectors`. Specification: `docs/spec/schedule.md`.
library;

export 'src/schedule/engine.dart';
export 'src/schedule/local_date.dart';
export 'src/schedule/rule.dart';
