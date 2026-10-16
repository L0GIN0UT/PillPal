import 'package:pillpal_core/pillpal_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  final morning = key('2026-10-16', '08:00');
  final persistent = source(level: ReminderLevel.persistent);

  List<NotificationRequest> requestsOf(ReminderPlan plan, String key) =>
      plan.requests.where((r) => r.occurrenceKey == key).toList();

  test('a snooze replaces the regular series of the occurrence', () {
    final result = plan([persistent], snoozed: {morning: utc(16, 5, 15)});
    final snoozed = requestsOf(result, morning);
    expect(snoozed.map((r) => r.fireAtUtc), [
      utc(16, 5, 15),
      utc(16, 5, 45),
      utc(16, 6, 15),
      utc(16, 6, 45),
    ]);
    expect(snoozed.map((r) => r.repeatIndex), [0, 1, 2, 3]);
    expect(snoozed.every((r) => r.isSnooze), isTrue);
    expect(snoozed.first.id, baseNotificationId('$morning#s0'));
    final regular = plan([persistent]);
    expect(requestsOf(regular, morning).single.fireAtUtc, utc(16, 5, 30));
  });

  test('non-repeating levels snooze once', () {
    final result = plan([source()], snoozed: {morning: utc(16, 5, 15)});
    expect(fires(result).first, (morning, 0, utc(16, 5, 15)));
    expect(requestsOf(result, morning), hasLength(1));
  });

  test('a handled occurrence ignores its snooze', () {
    final result = plan(
      [persistent],
      snoozed: {morning: utc(16, 5, 15)},
      handled: {morning},
    );
    expect(requestsOf(result, morning), isEmpty);
  });

  test('a past snooze still plans its remaining repeats', () {
    final result = plan([persistent], snoozed: {morning: utc(16, 4, 10)});
    expect(requestsOf(result, morning).map((r) => r.repeatIndex), [2, 3]);
    expect(requestsOf(result, morning).first.fireAtUtc, utc(16, 5, 10));
  });

  test('an occurrence older than the expansion window can be snoozed', () {
    final yesterday = key('2026-10-15', '20:00');
    final result = plan([source()], snoozed: {yesterday: utc(16, 5, 30)});
    expect(fires(result).first, (yesterday, 0, utc(16, 5, 30)));
  });

  test('a snooze series is not cut by the next occurrence', () {
    final result = plan([persistent], snoozed: {morning: utc(16, 15, 50)});
    expect(requestsOf(result, morning).map((r) => r.fireAtUtc), [
      utc(16, 15, 50),
      utc(16, 16, 20),
      utc(16, 16, 50),
      utc(16, 17, 20),
    ]);
    final evening = requestsOf(result, key('2026-10-16', '20:00'));
    expect(evening, hasLength(4));
  });

  test('a snooze beyond the horizon is not planned', () {
    final result = plan([source()], snoozed: {morning: utc(18, 6)});
    expect(requestsOf(result, morning), isEmpty);
  });

  test('a snooze of a disabled source is ignored', () {
    final disabled = source(enabled: false);
    final result = plan([disabled], snoozed: {morning: utc(16, 5, 15)});
    expect(result.requests, isEmpty);
  });

  test('stale or malformed snooze keys are ignored', () {
    final stale = <String, DateTime>{
      key('2026-10-16', '09:00'): utc(16, 6),
      key('2026-09-30', '08:00'): utc(16, 6),
      key('2026-10-16', '08:00', scheduleId: 'unknown'): utc(16, 6),
      '$sid/2026-10-16X08:00': utc(16, 6),
      '$sid/2026-13-01T08:00': utc(16, 6),
      '${sid}2026-10-16T08:00': utc(16, 6),
      'garbage': utc(16, 6),
      '': utc(16, 6),
    };
    final result = plan([source()], snoozed: stale);
    expect(result.requests, plan([source()]).requests);
  });

  test('a snooze does not depend on the zone of its source', () {
    final broken = source(tzMode: TzMode.fixed, fixedTz: 'Mars/Olympus');
    final result = plan([broken], snoozed: {morning: utc(16, 5, 15)});
    expect(result.unplannableScheduleIds, [sid]);
    expect(fires(result), [(morning, 0, utc(16, 5, 15))]);
  });
}
