import 'dart:convert';

/// Largest id the platforms accept: they use signed 32-bit ids.
const int maxNotificationId = 0x7fffffff;

/// Planner ids are in `1..plannerIdMask` (docs/spec/reminders.md §7).
const int plannerIdMask = 0x3fffffff;

/// First id the app may use for notifications not made by the planner.
const int firstAppNotificationId = plannerIdMask + 1;

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
int baseNotificationId(String input, {int idMask = plannerIdMask}) {
  final id = fnv1a32(input) & idMask;
  return id == 0 ? 1 : id;
}

/// Hands out unique ids in `1..idMask` (docs/spec/reminders.md §7).
///
/// [reserved] ids (held by retained notifications) are never handed out by
/// [allocate]; a request that already owns one takes it back with [claim].
class NotificationIdAllocator {
  /// Creates an allocator; [idMask] narrows the id space (tests only).
  NotificationIdAllocator({
    this.idMask = plannerIdMask,
    Iterable<int> reserved = const <int>[],
  }) {
    if (idMask < 1 || idMask > plannerIdMask) {
      throw RangeError.range(idMask, 1, plannerIdMask, 'idMask');
    }
    _taken.addAll(reserved.where(_inRange));
  }

  /// Ids are in `1..idMask`.
  final int idMask;

  /// Ids handed out or claimed in this allocation.
  final Set<int> _used = <int>{};

  /// [_used] plus the reserved ids.
  final Set<int> _taken = <int>{};

  bool _inRange(int id) => id >= 1 && id <= idMask;

  /// Takes [id] for a request that already owns it; false if it is out of
  /// range or was already handed out in this allocation.
  bool claim(int id) {
    if (!_inRange(id) || !_used.add(id)) {
      return false;
    }
    _taken.add(id);
    return true;
  }

  /// The base id of [input] if free, else the next free id after it,
  /// wrapping from `idMask` to 1. Throws [StateError] when none is free.
  int allocate(String input) {
    if (_taken.length >= idMask) {
      throw StateError('Notification id space exhausted');
    }
    var id = baseNotificationId(input, idMask: idMask);
    while (_taken.contains(id)) {
      id = id >= idMask ? 1 : id + 1;
    }
    _used.add(id);
    _taken.add(id);
    return id;
  }
}
