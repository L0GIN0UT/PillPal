import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/privacy/export_files.dart';

// Where the export archive lives on the device, and that nothing of it stays
// (privacy rules §1 and §7): one copy, in the cache directory, named by
// region and date only.

void main() {
  late Directory temp;
  late ExportFiles files;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('pillpal-export-files-');
    files = ExportFiles(() async => temp);
  });
  tearDown(() => temp.deleteSync(recursive: true));

  test('the name holds the region and the UTC date of the archive only', () {
    expect(
      ExportFiles.fileName('eu', DateTime.utc(2026, 1, 5, 23, 59)),
      'pillpal-export-eu-20260105.zip',
    );
    // A local time is turned into UTC first, like the server's file name.
    expect(
      ExportFiles.fileName('ru', DateTime.parse('2026-11-11T01:30:00+04:00')),
      'pillpal-export-ru-20261110.zip',
    );
  });

  test('the target is in the exports folder of the cache directory', () async {
    final file = await files.create('ru', DateTime.utc(2026, 11, 11, 8));

    expect(
      file.path.replaceAll(r'\', '/'),
      '${temp.path.replaceAll(r'\', '/')}/exports/'
      'pillpal-export-ru-20261111.zip',
    );
    expect(file.parent.existsSync(), isTrue);
    expect(file.existsSync(), isFalse, reason: 'the download writes it');
  });

  test('creating a target first removes any earlier archive', () async {
    final first = await files.create('ru', DateTime.utc(2026, 11, 10));
    first.writeAsBytesSync([1]);

    await files.create('ru', DateTime.utc(2026, 11, 11));

    expect(first.existsSync(), isFalse);
  });

  test('clear removes the folder and the copies of the share sheet only',
      () async {
    final file = await files.create('ru', DateTime.utc(2026, 11, 11));
    file.writeAsBytesSync([1]);
    Directory('${temp.path}/share_plus').createSync();
    final shared = File('${temp.path}/share_plus/pillpal-export-ru-1.zip')
      ..writeAsBytesSync([1]);
    final strayInCache = File('${temp.path}/pillpal-export-ru-2.zip')
      ..writeAsBytesSync([1]);
    final other = File('${temp.path}/share_plus/other.zip')
      ..writeAsBytesSync([1]);
    final report = File('${temp.path}/pillpal-report-a-b.pdf')
      ..writeAsBytesSync([1]);

    await files.clear();

    expect(file.existsSync(), isFalse);
    expect(Directory('${temp.path}/exports').existsSync(), isFalse);
    expect(shared.existsSync(), isFalse);
    expect(strayInCache.existsSync(), isFalse);
    expect(other.existsSync(), isTrue, reason: 'not an export');
    expect(report.existsSync(), isTrue, reason: 'reports have their own store');
  });

  test('clear never throws, even without a temporary directory', () async {
    final broken = ExportFiles(() async => throw const FileSystemException());

    await broken.clear();
  });

  test('clear with nothing to delete is fine', () async {
    await files.clear();
    await files.clear();
  });
}
