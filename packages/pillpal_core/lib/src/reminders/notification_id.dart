import 'dart:convert';

/// Largest notification id: platforms use signed 32-bit ids.
const int maxNotificationId = 0x7fffffff;

const int _fnvOffsetBasis = 0x811c9dc5;
const int _fnvPrime = 0x01000193;
const int _uint32Mask = 0xffffffff;

/// 32-bit FNV-1a hash of the UTF-8 bytes of [input].
///
/// Relies on 64-bit integer arithmetic (Dart VM / AOT), which is what the
/// mobile app runs on.
int fnv1a32(String input) {
  var hash = _fnvOffsetBasis;
  for (final byte in utf8.encode(input)) {
    hash = ((hash ^ byte) * _fnvPrime) & _uint32Mask;
  }
  return hash;
}

/// The string hashed into a notification id (docs/spec/reminders.md §7).
String notificationIdInput(
  String occurrenceKey,
  int repeatIndex, {
  required bool isSnooze,
}) {
  final marker = isSnooze ? 's' : '';
  return '$occurrenceKey#$marker$repeatIndex';
}

/// The base id of [input]: `fnv1a32(input) & idMask`, with 0 mapped to 1.
int baseNotificationId(String input, {int idMask = maxNotificationId}) {
  final id = fnv1a32(input) & idMask;
  return id == 0 ? 1 : id;
}

/// Hands out unique ids in `1..idMask`, resolving collisions by linear
/// probing in the order of [allocate] calls (docs/spec/reminders.md §7).
class NotificationIdAllocator {
  /// Creates an allocator; [idMask] narrows the id space (tests only).
  NotificationIdAllocator({this.idMask = maxNotificationId}) {
    if (idMask < 1 || idMask > maxNotificationId) {
      throw RangeError.range(idMask, 1, maxNotificationId, 'idMask');
    }
  }

  /// Ids are in `1..idMask`.
  final int idMask;

  final Set<int> _used = <int>{};

  /// The base id of [input] if free, else the next free id after it.
  ///
  /// Throws [StateError] when all `idMask` ids are taken.
  int allocate(String input) {
    if (_used.length >= idMask) {
      throw StateError('Notification id space exhausted');
    }
    var id = baseNotificationId(input, idMask: idMask);
    while (!_used.add(id)) {
      id = id >= idMask ? 1 : id + 1;
    }
    return id;
  }
}
