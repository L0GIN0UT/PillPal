import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/schedule/schedule_edit.dart';
import 'package:pillpal_core/pillpal_core.dart';

final LocalDate _today = LocalDate(2026, 10, 16);

ScheduleRule _rule({
  String kind = 'daily',
  String start = '2026-10-01',
  String? end,
  String time = '08:00',
  int? interval,
}) =>
    ScheduleRule.fromJson({
      'v': 1,
      'kind': kind,
      'start_date': start,
      'end_date': end,
      if (interval != null) 'interval_days': interval,
      'times': [
        {
          'time': time,
          'dose': {'amount': '1', 'unit': 'tablet'},
        },
      ],
    });

ScheduleEditPlan _plan(ScheduleRule current, ScheduleRule edited) =>
    planScheduleEdit(current: current, edited: edited, today: _today);

void main() {
  test('an unchanged rule writes nothing', () {
    expect(_plan(_rule(), _rule()), isA<KeepSchedule>());
  });

  test('a schedule starting today or later is edited in place', () {
    final plan = _plan(
      _rule(start: '2026-10-16'),
      _rule(start: '2026-10-16', time: '09:00'),
    );
    expect(plan, isA<EditInPlace>());
  });

  test('a started schedule is split: ends yesterday, continues today', () {
    final plan = _plan(_rule(), _rule(time: '09:00'));
    expect(plan, isA<SplitSchedule>());
    final split = plan as SplitSchedule;
    expect(split.endDate, LocalDate(2026, 10, 15));
    expect(split.rule['start_date'], '2026-10-16');
    expect(split.rule['times'], [
      {
        'time': '09:00',
        'dose': {'amount': '1', 'unit': 'tablet'},
      },
    ]);
  });

  test('a later edited start is kept', () {
    final plan = _plan(_rule(), _rule(start: '2026-10-20')) as SplitSchedule;
    expect(plan.rule['start_date'], '2026-10-20');
  });

  test('an interval keeps its phase from today', () {
    // Every 3 days from Oct 1: Oct 16 is a dose day, Oct 17 is not.
    expect(
      continuationStart(_rule(kind: 'interval_days', interval: 3), _today),
      LocalDate(2026, 10, 16),
    );
    expect(
      continuationStart(
        _rule(kind: 'interval_days', interval: 3),
        LocalDate(2026, 10, 17),
      ),
      LocalDate(2026, 10, 19),
    );
  });

  test('moving only the course end does not split', () {
    expect(_plan(_rule(), _rule(end: '2026-12-31')), isA<EditInPlace>());
  });

  test('ending a started schedule before today is refused', () {
    expect(
      () => _plan(_rule(), _rule(time: '09:00', end: '2026-10-10')),
      throwsA(
        isA<ScheduleEditException>().having(
          (e) => e.error,
          'error',
          ScheduleEditError.endsBeforeToday,
        ),
      ),
    );
  });

  test('an ended schedule is not edited', () {
    expect(
      () => _plan(_rule(end: '2026-10-10'), _rule()),
      throwsA(
        isA<ScheduleEditException>().having(
          (e) => e.error,
          'error',
          ScheduleEditError.ended,
        ),
      ),
    );
  });
}
