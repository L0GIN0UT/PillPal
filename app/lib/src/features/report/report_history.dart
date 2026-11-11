import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../data/clock.dart';
import '../../data/db/database.dart';
import '../../data/providers.dart';
import 'report_files.dart';
import 'report_model.dart';

/// The folder of the app's private storage that holds one sub-folder per
/// stored report (`<support>/reports/<id>/`).
const String storedReportsFolder = 'reports';

/// The PDF reports kept on this device (docs/adr/0019).
///
/// Metadata is in the `stored_reports` table, the file at
/// `<support>/reports/<id>/pillpal-report-<first>-<last>.pdf`: dates only in
/// the name, no patient name or medication. All operations run one at a time
/// so that a file written for a new row is never taken for an orphan.
class ReportHistory {
  /// Creates the history over [db]. [supportDirectory] is
  /// `getApplicationSupportDirectory` (Android `filesDir`); [clock] and
  /// [newId] are injected for tests.
  ReportHistory({
    required AppDatabase db,
    required Future<Directory> Function() supportDirectory,
    required Clock clock,
    required IdGenerator newId,
    this.maxCount = maxStoredReports,
    this.maxAge = storedReportRetention,
  })  : _db = db,
        _supportDirectory = supportDirectory,
        _clock = clock,
        _newId = newId;

  /// Most reports kept.
  final int maxCount;

  /// Oldest age kept.
  final Duration maxAge;

  final AppDatabase _db;
  final Future<Directory> Function() _supportDirectory;
  final Clock _clock;
  final IdGenerator _newId;
  Future<void> _tail = Future<void>.value();

  /// The kept reports, newest first.
  Stream<List<StoredReport>> watchAll() {
    final query = _db.select(_db.storedReports)
      ..orderBy([
        (row) => OrderingTerm.desc(row.createdAt),
        (row) => OrderingTerm.desc(row.id),
      ]);
    return query.watch();
  }

  /// The kept reports, newest first.
  Future<List<StoredReport>> all() {
    final query = _db.select(_db.storedReports)
      ..orderBy([
        (row) => OrderingTerm.desc(row.createdAt),
        (row) => OrderingTerm.desc(row.id),
      ]);
    return query.get();
  }

  /// Keeps [bytes] as the report of [range] for [profileId]. Expired
  /// reports and, at the limit, the oldest ones are deleted first.
  Future<StoredReport> add({
    required String profileId,
    required ReportRange range,
    required bool includeHidden,
    required Uint8List bytes,
  }) {
    return _serial(() async {
      await _expire();
      await _makeRoom();
      final id = _newId();
      final folder = await _folderOf(id);
      await folder.create(recursive: true);
      final name = '$reportFilePrefix${range.first}-${range.last}.pdf';
      final row = StoredReport(
        id: id,
        profileId: profileId,
        firstDay: range.first.toString(),
        lastDay: range.last.toString(),
        includeHidden: includeHidden,
        createdAt: _clock().microsecondsSinceEpoch,
        sizeBytes: bytes.length,
      );
      try {
        await File('${folder.path}/$name').writeAsBytes(bytes, flush: true);
        await _db.into(_db.storedReports).insert(row);
      } on Object {
        // Neither a file without a row nor a row without a file.
        await _deleteFolder(folder);
        rethrow;
      }
      return row;
    });
  }

  /// The file of [report] (it may be missing until [reconcile] runs).
  Future<File> fileOf(StoredReport report) async {
    final folder = await _folderOf(report.id);
    final name = '$reportFilePrefix${report.firstDay}-${report.lastDay}.pdf';
    return File('${folder.path}/$name');
  }

  /// Deletes one report: row and file.
  Future<void> delete(String id) => _serial(() => _remove([id]));

  /// Deletes every report: the whole `reports` folder, then the rows. Used
  /// on sign-out and when another account signs in; never throws (nothing is
  /// logged). The folder is tried twice and the rows stay if it still
  /// cannot be deleted, so `reconcile` can retry; on those paths the account
  /// wipe has already removed the rows (docs/adr/0019 §4).
  Future<void> deleteAll() => _serial(() async {
        var removed = false;
        for (var attempt = 0; attempt < 2 && !removed; attempt++) {
          try {
            final root = await _root();
            if (await root.exists()) {
              await root.delete(recursive: true);
            }
            removed = true;
          } on Object {
            // No storage (tests) or a file in use: once more, then reconcile.
          }
        }
        if (!removed) {
          return;
        }
        try {
          await _db.delete(_db.storedReports).go();
        } on Object {
          // The database is closing: the rows go with the account wipe.
        }
      });

  /// Makes disk and table agree (start, after sync): deletes reports older
  /// than [maxAge], rows whose profile is gone (or deleted) or whose file is missing, and
  /// files or folders that have no row.
  Future<void> reconcile() => _serial(() async {
        await _expire();
        // A deleted (tombstoned) profile counts as gone.
        final profiles = {
          for (final row in await (_db.select(_db.profiles)
                ..where((p) => p.deletedAt.isNull()))
              .get())
            row.id,
        };
        final stale = <String>[];
        for (final report in await _db.select(_db.storedReports).get()) {
          if (!profiles.contains(report.profileId) ||
              !await (await fileOf(report)).exists()) {
            stale.add(report.id);
          }
        }
        await _remove(stale);
        await _deleteOrphans(await _root());
      });

  Future<void> _expire() async {
    final cutoff = _clock().subtract(maxAge).microsecondsSinceEpoch;
    final expired = await (_db.select(_db.storedReports)
          ..where((row) => row.createdAt.isSmallerThanValue(cutoff)))
        .get();
    await _remove([for (final row in expired) row.id]);
  }

  /// Leaves space for one more: deletes the oldest while the limit is hit.
  Future<void> _makeRoom() async {
    final kept = await all();
    final surplus = kept.length - (maxCount - 1);
    if (surplus > 0) {
      await _remove([
        for (final row in kept.reversed.take(surplus)) row.id,
      ]);
    }
  }

  Future<void> _remove(List<String> ids) async {
    if (ids.isEmpty) {
      return;
    }
    await (_db.delete(_db.storedReports)..where((row) => row.id.isIn(ids)))
        .go();
    for (final id in ids) {
      await _deleteFolder(await _folderOf(id));
    }
  }

  Future<void> _deleteOrphans(Directory root) async {
    if (!await root.exists()) {
      return;
    }
    final known = {
      for (final row in await _db.select(_db.storedReports).get()) row.id,
    };
    try {
      await for (final entry in root.list(followLinks: false)) {
        if (entry is Directory && known.contains(_nameOf(entry))) {
          await _deleteStrays(entry);
        } else {
          await _delete(entry);
        }
      }
    } on FileSystemException {
      // Unreadable folder: the next reconcile retries.
    }
  }

  /// In a known report's folder only the PDF may stay.
  Future<void> _deleteStrays(Directory folder) async {
    await for (final entry in folder.list(followLinks: false)) {
      final name = _nameOf(entry);
      final isReport = entry is File &&
          name.startsWith(reportFilePrefix) &&
          name.endsWith('.pdf');
      if (!isReport) {
        await _delete(entry);
      }
    }
  }

  String _nameOf(FileSystemEntity entry) =>
      entry.uri.pathSegments.where((part) => part.isNotEmpty).last;

  Future<void> _delete(FileSystemEntity entry) async {
    try {
      await entry.delete(recursive: true);
    } on FileSystemException {
      // In use: the next reconcile retries.
    }
  }

  Future<void> _deleteFolder(Directory folder) async {
    if (await folder.exists()) {
      await _delete(folder);
    }
  }

  Future<Directory> _root() async =>
      Directory('${(await _supportDirectory()).path}/$storedReportsFolder');

  Future<Directory> _folderOf(String id) async =>
      Directory('${(await _root()).path}/$id');

  /// Runs [action] after the earlier ones, whether or not they failed.
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

/// Where stored reports live (Android `filesDir`); tests override it.
final reportSupportDirectoryProvider = Provider<Future<Directory> Function()>(
  (ref) => getApplicationSupportDirectory,
);

/// The reports kept on this device.
final reportHistoryProvider = Provider<ReportHistory>(
  (ref) => ReportHistory(
    db: ref.watch(databaseProvider),
    supportDirectory: ref.watch(reportSupportDirectoryProvider),
    clock: ref.watch(clockProvider),
    newId: newUuid,
  ),
);

/// The kept reports, newest first (the list screen reads it).
final storedReportsProvider = StreamProvider<List<StoredReport>>(
  (ref) => ref.watch(reportHistoryProvider).watchAll(),
);
