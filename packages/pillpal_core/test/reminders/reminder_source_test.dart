import 'package:pillpal_core/pillpal_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('validation', () {
    test('ids must not be empty', () {
      expect(() => source(scheduleId: ''), throwsArgumentError);
      expect(() => source(medicationId: ''), throwsArgumentError);
    });

    test('fixed mode needs a zone', () {
      expect(() => source(tzMode: TzMode.fixed), throwsArgumentError);
      expect(
        () => source(tzMode: TzMode.fixed, fixedTz: ''),
        throwsArgumentError,
      );
    });

    test('repeat interval range', () {
      expect(() => source(every: 0), throwsArgumentError);
      expect(
        () => source(every: maxRepeatEveryMinutes + 1),
        throwsArgumentError,
      );
      expect(source(every: minRepeatEveryMinutes).repeatEveryMinutes, 1);
      expect(source(every: maxRepeatEveryMinutes).repeatEveryMinutes, 720);
    });

    test('repeat count range', () {
      expect(() => source(repeats: -1), throwsArgumentError);
      expect(() => source(repeats: maxRepeatsLimit + 1), throwsArgumentError);
      expect(source(repeats: 0).maxRepeats, 0);
      expect(source(repeats: maxRepeatsLimit).maxRepeats, 50);
    });
  });

  test('only persistent and alarm repeat', () {
    expect(ReminderLevel.quiet.repeats, isFalse);
    expect(ReminderLevel.normal.repeats, isFalse);
    expect(ReminderLevel.persistent.repeats, isTrue);
    expect(ReminderLevel.alarm.repeats, isTrue);
    expect(source(repeats: 5).effectiveRepeats, 0);
    expect(source(level: ReminderLevel.alarm, repeats: 5).effectiveRepeats, 5);
  });

  test('effective zone', () {
    expect(source().effectiveTz('Asia/Tokyo'), 'Asia/Tokyo');
    final fixed = source(tzMode: TzMode.fixed, fixedTz: samara);
    expect(fixed.effectiveTz('Asia/Tokyo'), samara);
  });

  test('defaults', () {
    final minimal = ReminderSource(
      medicationId: mid,
      scheduleId: sid,
      rule: dailyRule(['08:00']),
      level: ReminderLevel.normal,
    );
    expect(minimal.tzMode, TzMode.local);
    expect(minimal.fixedTz, isNull);
    expect(minimal.repeatEveryMinutes, defaultRepeatEveryMinutes);
    expect(minimal.maxRepeats, 0);
    expect(minimal.enabled, isTrue);
  });

  group('NotificationRequest', () {
    NotificationRequest make(DateTime fireAt) => NotificationRequest(
          id: 7,
          occurrenceKey: key('2026-10-16', '08:00'),
          medicationId: mid,
          scheduleId: sid,
          fireAtUtc: fireAt,
          repeatIndex: 1,
          level: ReminderLevel.alarm,
          isSnooze: true,
        );

    test('stores the fire time in UTC', () {
      final local = DateTime.fromMillisecondsSinceEpoch(0);
      expect(make(local).fireAtUtc.isUtc, isTrue);
      expect(make(local), make(DateTime.utc(1970)));
    });

    test('value equality', () {
      expect(make(utc(16, 4)), make(utc(16, 4)));
      expect(make(utc(16, 4)).hashCode, make(utc(16, 4)).hashCode);
      expect(make(utc(16, 4)), isNot(make(utc(16, 5))));
    });

    test('toString does not expose the occurrence key', () {
      final text = make(utc(16, 4)).toString();
      expect(text, contains('id: 7'));
      expect(text, isNot(contains(sid)));
    });
  });
}
