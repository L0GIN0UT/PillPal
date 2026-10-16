import 'package:pillpal_core/pillpal_core.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('fnv1a32 matches the reference vectors', () {
    expect(fnv1a32(''), 0x811c9dc5);
    expect(fnv1a32('a'), 0xe40c292c);
    expect(fnv1a32('foobar'), 0xbf9cf968);
  });

  test('id input distinguishes repeats and snoozes', () {
    final morning = key('2026-10-16', '08:00');
    expect(notificationIdInput(morning, 0, isSnooze: false), '$morning#0');
    expect(notificationIdInput(morning, 2, isSnooze: true), '$morning#s2');
  });

  // Changing these orphans notifications that are already pending.
  test('base ids are pinned', () {
    final morning = key('2026-10-16', '08:00');
    expect(baseNotificationId('$morning#0'), 1492402891);
    expect(baseNotificationId('$morning#1'), 1475625272);
    expect(baseNotificationId('$morning#s0'), 149495530);
  });

  test('a base id of 0 becomes 1', () {
    // fnv1a32('x3') & 3 == 0.
    expect(fnv1a32('x3') & 3, 0);
    expect(baseNotificationId('x3', idMask: 3), 1);
  });

  group('allocator', () {
    test('collisions take the next free id', () {
      final allocator = NotificationIdAllocator(idMask: 3);
      expect(allocator.allocate('x0'), 1);
      expect(allocator.allocate('x4'), 2); // base 1 is taken
      expect(allocator.allocate('x2'), 3);
    });

    test('probing wraps from idMask to 1', () {
      final allocator = NotificationIdAllocator(idMask: 3);
      expect(allocator.allocate('x2'), 3);
      expect(allocator.allocate('x6'), 1); // base 3 is taken
      expect(allocator.allocate('x0'), 2); // base 1 is taken
    });

    test('an exhausted id space is an error', () {
      final allocator = NotificationIdAllocator(idMask: 1);
      expect(allocator.allocate('x0'), 1);
      expect(() => allocator.allocate('x1'), throwsStateError);
    });

    test('idMask must be in 1..2^31-1', () {
      expect(() => NotificationIdAllocator(idMask: 0), throwsArgumentError);
      expect(
        () => NotificationIdAllocator(idMask: maxNotificationId + 1),
        throwsArgumentError,
      );
    });
  });

  group('planner ids', () {
    test('collisions are resolved in plan order', () {
      // Base ids under mask 3: 16T20:00 -> 1, 17T08:00 -> 0 -> 1,
      // 17T20:00 -> 2.
      final result = plan([source()], budget: 3, idMask: 3);
      expect(result.requests.map((r) => r.id), [1, 2, 3]);
    });

    test('ids are unique, positive and 31-bit', () {
      final sources = [
        for (var i = 0; i < 50; i++)
          source(
            scheduleId: '00000000-0000-4000-8000-0000000000${10 + i}',
            rule: dailyRule(['07:00', '13:00', '19:00']),
            level: ReminderLevel.persistent,
            every: 10,
            repeats: 6,
          ),
      ];
      final ids = plan(sources).requests.map((r) => r.id).toList();
      expect(ids.toSet(), hasLength(ids.length));
      expect(ids.every((id) => id >= 1 && id <= maxNotificationId), isTrue);
    });

    test('regular ids use the base id of key#repeatIndex', () {
      final result = plan([source(level: ReminderLevel.persistent)]);
      for (final request in result.requests) {
        final input = '${request.occurrenceKey}#${request.repeatIndex}';
        expect(request.id, baseNotificationId(input));
      }
    });
  });
}
