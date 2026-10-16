import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Prefix of report file names (dates only follow, no medical data).
const String reportFilePrefix = 'pillpal-report-';

/// Folder of the app's temporary directory that holds the report.
const String reportsFolder = 'reports';

/// Folder of the app's temporary directory where the `printing` plugin
/// copies a shared PDF on Android (`cacheDir/share`; there
/// `getTemporaryDirectory()` is the cache directory). On iOS the plugin
/// writes into `NSTemporaryDirectory()` (`tmp/`, [Directory.systemTemp]),
/// not into `getTemporaryDirectory()` (`Library/Caches`).
const String printingShareFolder = 'share';

/// The PDF copies a report leaves on the device (privacy rules §1, §7): the
/// one in `<tmp>/reports` and the copies the share plugin makes (in
/// `<tmp>/share`, or anywhere under the system temp directory). They are
/// removed before each new report, on app start and on sign-out or an
/// account switch, so a report never outlives the session it was made in.
class ReportFiles {
  /// Creates the store over [temporaryDirectory] (`getTemporaryDirectory`)
  /// and [systemTemp] (the process temp directory, iOS `tmp/`).
  const ReportFiles(
    this._temporaryDirectory, {
    Directory Function() systemTemp = _processTemp,
  }) : _systemTemp = systemTemp;

  final Future<Directory> Function() _temporaryDirectory;
  final Directory Function() _systemTemp;

  static Directory _processTemp() => Directory.systemTemp;

  /// Writes [bytes] as [name] into `<tmp>/reports` (after [clear]).
  Future<File> write(Uint8List bytes, String name) async {
    await clear();
    final temp = await _temporaryDirectory();
    final folder = Directory('${temp.path}/$reportsFolder');
    await folder.create(recursive: true);
    return File('${folder.path}/$name').writeAsBytes(bytes, flush: true);
  }

  /// Deletes every report copy; never throws (nothing is logged).
  Future<void> clear() async {
    try {
      final temp = await _temporaryDirectory();
      final folder = Directory('${temp.path}/$reportsFolder');
      if (await folder.exists()) {
        await folder.delete(recursive: true);
      }
      for (final dir in [
        temp,
        Directory('${temp.path}/$printingShareFolder')
      ]) {
        await _deleteReports(dir);
      }
    } on Object {
      // No temporary directory (tests) or a file in use: the next clear
      // retries.
    }
    try {
      // iOS: the share copy lands in NSTemporaryDirectory(), at any depth.
      await _deleteReports(_systemTemp(), recursive: true);
    } on Object {
      // A file in use: the next clear retries.
    }
  }

  Future<void> _deleteReports(Directory dir, {bool recursive = false}) async {
    if (!await dir.exists()) {
      return;
    }
    // Unreadable subfolders are skipped, not fatal.
    final entries = dir
        .list(recursive: recursive, followLinks: false)
        .handleError((Object _) {});
    await for (final entry in entries) {
      final name = entry.uri.pathSegments.last;
      if (entry is File &&
          name.startsWith(reportFilePrefix) &&
          name.endsWith('.pdf')) {
        await entry.delete();
      }
    }
  }
}

/// The report files of this device (tests override it with a temp folder).
final reportFilesProvider = Provider<ReportFiles>(
  (ref) => const ReportFiles(getTemporaryDirectory),
);
