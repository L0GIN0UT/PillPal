import 'dart:convert';
import 'dart:io';

import '../data/clock.dart';

/// How long the device remembers that an alert was resolved: longer than a
/// push stays deliverable, so a `missed` push that overtakes its `resolved`
/// one (separate deliveries have no order) is still recognised.
const Duration resolvedAlertMemory = Duration(hours: 24);

/// Most alerts remembered at once.
const int resolvedAlertMemoryEntries = 200;

/// Which alerts were already resolved, so a late `missed` push for one of
/// them is not shown (ADR 0008 §2). Holds opaque alert ids only.
abstract interface class ResolvedAlerts {
  /// Whether [alertId] was resolved within the memory.
  Future<bool> wasResolved(String alertId);

  /// Notes that [alertId] was resolved.
  Future<void> remember(String alertId);
}

/// [ResolvedAlerts] in a small JSON file (`alert id -> epoch milliseconds`)
/// in the app's private storage. A file rather than the database: the
/// background isolate of a data-only push has no better shared state, and
/// nothing here needs a schema or a migration. Never throws: when the file
/// cannot be read or written the alert is simply shown.
class FileResolvedAlerts implements ResolvedAlerts {
  /// Creates the memory in the directory [directory] returns.
  FileResolvedAlerts({
    required Future<Directory> Function() directory,
    required Clock clock,
    this.maxEntries = resolvedAlertMemoryEntries,
  })  : _directory = directory,
        _clock = clock;

  static const String _fileName = 'resolved_alerts.json';

  /// Most entries kept; the oldest go first.
  final int maxEntries;

  final Future<Directory> Function() _directory;
  final Clock _clock;

  @override
  Future<bool> wasResolved(String alertId) async {
    try {
      final entries = _live(await _read());
      return entries.containsKey(alertId);
    } on Object {
      return false;
    }
  }

  @override
  Future<void> remember(String alertId) async {
    try {
      final entries = _live(await _read());
      entries[alertId] = _clock().millisecondsSinceEpoch;
      final kept = entries.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      await _write({
        for (final entry in kept.take(maxEntries)) entry.key: entry.value,
      });
    } on Object {
      // Intentionally silent: see the class comment.
    }
  }

  Map<String, int> _live(Map<String, int> entries) {
    final oldest =
        _clock().subtract(resolvedAlertMemory).millisecondsSinceEpoch;
    return {
      for (final entry in entries.entries)
        if (entry.value > oldest) entry.key: entry.value,
    };
  }

  Future<File> _file() async => File('${(await _directory()).path}/$_fileName');

  Future<Map<String, int>> _read() async {
    final file = await _file();
    if (!file.existsSync()) {
      return {};
    }
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is! Map<String, Object?>) {
        return {};
      }
      return {
        for (final entry in json.entries)
          if (entry.value is int) entry.key: entry.value! as int,
      };
    } on FormatException {
      return {};
    }
  }

  Future<void> _write(Map<String, int> entries) async {
    final file = await _file();
    await file.writeAsString(jsonEncode(entries), flush: true);
  }
}
