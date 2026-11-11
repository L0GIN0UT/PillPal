import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Prefix of report file names (dates only follow, no medical data).
const String reportFilePrefix = 'pillpal-report-';

/// Folder of the app's temporary directory where reports were kept before
/// the device-side history (docs/adr/0019); cleaned for old installs.
const String reportsFolder = 'reports';

/// Folder of the app's temporary directory where the `printing` plugin
/// copies a shared PDF on Android (`cacheDir/share`; there
/// `getTemporaryDirectory()` is the cache directory). On iOS the plugin
/// writes into `NSTemporaryDirectory()` (`tmp/`, [Directory.systemTemp]),
/// not into `getTemporaryDirectory()` (`Library/Caches`).
const String printingShareFolder = 'share';

/// The temporary PDF copies the share plugin leaves (privacy rules §1, §7):
/// `<tmp>/share` on Android, anywhere under the system temp directory on iOS,
/// and the old `<tmp>/reports`. The kept reports are not here: they are in
/// the app's private storage under `ReportHistory`. These copies are removed
/// on app start and on sign-out or an account switch.
class ReportFiles {
  /// Creates the store over [temporaryDirectory] (`getTemporaryDirectory`)
  /// and [systemTemp] (where the share plugin writes on iOS; null where it
  /// does not, so nothing outside the app's folders is scanned).
  const ReportFiles(
    this._temporaryDirectory, {
    Directory? Function() systemTemp = _iosProcessTemp,
  }) : _systemTemp = systemTemp;

  final Future<Directory> Function() _temporaryDirectory;
  final Directory? Function() _systemTemp;

  /// iOS `NSTemporaryDirectory()` (`tmp/` in the app sandbox). Android's
  /// share copies are in `<cache>/share`, covered by the temporary folder.
  static Directory? _iosProcessTemp() =>
      Platform.isIOS ? Directory.systemTemp : null;

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
      final systemTemp = _systemTemp();
      if (systemTemp != null) {
        await _deleteReports(systemTemp, recursive: true);
      }
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
