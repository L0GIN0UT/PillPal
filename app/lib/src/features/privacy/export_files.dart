import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

/// Prefix of the export file names (the region and a date follow, nothing
/// else).
const String exportFilePrefix = 'pillpal-export-';

/// Folder of the app's temporary directory that holds the archive.
const String exportsFolder = 'exports';

/// Folder of the app's temporary directory where `share_plus` copies a shared
/// file on Android (`cacheDir/share_plus`; there `getTemporaryDirectory()` is
/// the cache directory).
const String sharePlusFolder = 'share_plus';

/// The copies of the export archive a device may hold (privacy rules §1, §7).
///
/// The archive is the most concentrated medical artefact the system makes, so
/// it lives only in the cache directory (not backed up: Android keeps
/// `cacheDir` out of backups) and is removed after sharing, when the export
/// screen is left, at app start and on sign-out or an account switch. Its
/// path, its id and its content are never logged; the name holds the region
/// and a date only.
class ExportFiles {
  /// Creates the store over [_temporaryDirectory] (`getTemporaryDirectory`).
  const ExportFiles(this._temporaryDirectory);

  final Future<Directory> Function() _temporaryDirectory;

  /// The file name for an archive of [region] that became ready at [readyAt].
  static String fileName(String region, DateTime readyAt) {
    final utc = readyAt.toUtc();
    final month = utc.month.toString().padLeft(2, '0');
    final day = utc.day.toString().padLeft(2, '0');
    return '$exportFilePrefix$region-${utc.year}$month$day.zip';
  }

  /// An empty target file in `<tmp>/exports` (after [clear], so there is never
  /// more than one archive on the device). The file itself is not created: the
  /// download writes it.
  Future<File> create(String region, DateTime readyAt) async {
    await clear();
    final temp = await _temporaryDirectory();
    final folder = Directory('${temp.path}/$exportsFolder');
    await folder.create(recursive: true);
    return File('${folder.path}/${fileName(region, readyAt)}');
  }

  /// Deletes every copy of an archive; never throws (nothing is logged).
  Future<void> clear() async {
    try {
      final temp = await _temporaryDirectory();
      final folder = Directory('${temp.path}/$exportsFolder');
      if (await folder.exists()) {
        await folder.delete(recursive: true);
      }
      for (final dir in [temp, Directory('${temp.path}/$sharePlusFolder')]) {
        await _deleteExports(dir);
      }
    } on Object {
      // No temporary directory (tests) or a file in use: the next clear
      // retries.
    }
  }

  Future<void> _deleteExports(Directory dir) async {
    if (!await dir.exists()) {
      return;
    }
    // Unreadable entries are skipped, not fatal.
    final entries = dir.list(followLinks: false).handleError((Object _) {});
    await for (final entry in entries) {
      final name = entry.uri.pathSegments.last;
      if (entry is File &&
          name.startsWith(exportFilePrefix) &&
          name.endsWith('.zip')) {
        await entry.delete();
      }
    }
  }
}

/// The export files of this device (tests override it with a temp folder).
final exportFilesProvider = Provider<ExportFiles>(
  (ref) => const ExportFiles(getTemporaryDirectory),
);
