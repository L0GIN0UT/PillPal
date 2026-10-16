import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/schedule/schedule_draft.dart';
import 'package:pillpal_core/pillpal_core.dart';

void main() {
  final today = LocalDate(2026, 10, 16); // a Friday
  final initial = ScheduleDraft.initial(today);

  Map<String, Object?> canonical(ScheduleDraft draft) {
    expect(draft.validate(), isEmpty);
    final json = draft.toRuleJson();
    // The engine accepts it and its canonical form is identical.
    expect(ScheduleRule.fromJson(json).toJson(), json);
    return json;
  }

  test('daily with two times and per-time doses', () {
    final draft = initial.addSlot().updateSlot(
          1,
          const SlotDraft(time: '20:00', amount: '0,5', unit: DoseUnit.capsule),
        );
    expect(canonical(draft), {
      'v': 1,
      'kind': 'daily',
      'start_date': '2026-10-16',
      'end_date': null,
      'times': [
        {
          'time': '08:00',
          'dose': {'amount': '1', 'unit': 'tablet'},
        },
        {
          'time': '20:00',
          'dose': {'amount': '0.5', 'unit': 'capsule'},
        },
      ],
    });
  });

  test('weekdays are sorted ISO numbers', () {
    final draft = initial
        .copyWith(kind: RuleKind.weekdays)
        .toggleWeekday(1)
        .toggleWeekday(3);
    final json = canonical(draft);
    expect(json['weekdays'], [1, 3, 5]);
    expect(json.containsKey('interval_days'), isFalse);
  });

  test('interval days with a course end', () {
    final draft = initial
        .copyWith(kind: RuleKind.intervalDays, endDate: LocalDate(2027, 1, 15))
        .withInterval(3);
    final json = canonical(draft);
    expect(json['interval_days'], 3);
    expect(json['end_date'], '2027-01-15');
    expect(json.containsKey('weekdays'), isFalse);
  });

  test('as needed has no times', () {
    final json = canonical(initial.copyWith(kind: RuleKind.asNeeded));
    expect(json['kind'], 'as_needed');
    expect(json['times'], isEmpty);
  });

  test('invalid drafts report their problems', () {
    expect(
      initial.copyWith(kind: RuleKind.weekdays).toggleWeekday(5).validate(),
      [ScheduleDraftError.weekdaysEmpty],
    );
    expect(
      initial
          .updateSlot(
            0,
            const SlotDraft(time: '08:00', amount: '0', unit: DoseUnit.tablet),
          )
          .validate(),
      [ScheduleDraftError.amountInvalid],
    );
    expect(
      initial.copyWith(endDate: LocalDate(2026, 10, 1)).validate(),
      [ScheduleDraftError.endBeforeStart],
    );
    expect(
      initial.removeSlot(0).validate(),
      [ScheduleDraftError.timesEmpty],
    );
    expect(initial.withInterval(1).intervalDays, RuleLimits.minInterval);
  });

  test('added slots get distinct times', () {
    var draft = initial;
    for (var i = 0; i < 30; i++) {
      draft = draft.addSlot();
    }
    expect(draft.slots, hasLength(RuleLimits.maxSlots));
    expect(
        {for (final s in draft.slots) s.time}, hasLength(RuleLimits.maxSlots));
    expect(draft.validate(), isEmpty);
  });

  test('a stored rule round-trips through the draft', () {
    final rule = ScheduleRule.fromJson({
      'v': 1,
      'kind': 'weekdays',
      'start_date': '2026-10-01',
      'end_date': null,
      'weekdays': [2, 4],
      'times': [
        {
          'time': '07:30',
          'dose': {'amount': '2', 'unit': 'drop'},
        },
      ],
    });
    expect(ScheduleDraft.fromRule(rule).toRuleJson(), rule.toJson());
  });
}
