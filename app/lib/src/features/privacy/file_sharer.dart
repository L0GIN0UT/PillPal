import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

/// What came of offering the archive to the system share sheet.
enum ShareOutcome {
  /// The user picked a target: the archive left the app.
  shared,

  /// The sheet was closed, or the platform cannot say: the archive may not
  /// have left, so the file stays until the export screen is left.
  notShared,
}

/// Offers [file] (the export archive) to the system share sheet.
typedef ArchiveSharer = Future<ShareOutcome> Function(File file);

/// The system share sheet; tests replace it. Only a completed share counts
/// as shared. The file is kept either way: the archive cannot be fetched again
/// (it is handed out once), and a target may still be reading it.
final archiveSharerProvider = Provider<ArchiveSharer>(
  (ref) => (file) async {
    final result = await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path, mimeType: 'application/zip')]),
    );
    return result.status == ShareResultStatus.success
        ? ShareOutcome.shared
        : ShareOutcome.notShared;
  },
);
