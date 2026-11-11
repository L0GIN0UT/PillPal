import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/features/report/report_history.dart';
import 'package:pillpal/src/features/report/report_model.dart';
import 'package:pillpal_core/pillpal_core.dart';

/// The device-side report history (docs/adr/0019): real drift database in
/// memory, real files in a temp folder, a fake clock.
void main() {
  late AppDatabase db;
  late Directory support;
  late DateTime now;
  late int counter;
  late ReportHistory history;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    db = AppDatabase(NativeDatabase.memory());
    support = Directory.systemTemp.createTempSync('pillpal-history-');
    now = DateTime.utc(2026, 10, 16, 10);
    counter = 0;
    history = ReportHistory(
      db: db,
      supportDirectory: () async => support,
      clock: () => now,
      newId: () => 'id-${counter++}',
    );
    addTearDown(() async {
      await db.close();
      support.deleteSync(recursive: true);
    });
    await _profile(db, 'p1');
  });

  Future<StoredReport> add({
    String profileId = 'p1',
    int firstDay = 10,
    bool includeHidden = true,
  }) =>
      history.add(
        profileId: profileId,
        range: (
          first: LocalDate(2026, 10, firstDay),
          last: LocalDate(2026, 10, 16),
        ),
        includeHidden: includeHidden,
        bytes: Uint8List.fromList(const [1, 2, 3]),
      );

  Directory folder(String id) => Directory('${support.path}/reports/$id');

  test('add writes the PDF under reports/<id> with dates only in the name',
      () async {
    final report = await add();

    expect(report.id, 'id-0');
    expect(
      (report.firstDay, report.lastDay, report.sizeBytes),
      ('2026-10-10', '2026-10-16', 3),
    );
    expect(report.createdAt, now.microsecondsSinceEpoch);
    final file = await history.fileOf(report);
    expect(
      file.path.replaceAll(r'\', '/'),
      '${support.path.replaceAll(r'\', '/')}/reports/id-0/'
      'pillpal-report-2026-10-10-2026-10-16.pdf',
    );
    expect(await file.readAsBytes(), [1, 2, 3]);
    expect(await history.all(), [report]);
  });

  test('lists newest first', () async {
    await add();
    now = now.add(const Duration(hours: 1));
    await add(firstDay: 11);
    now = now.add(const Duration(hours: 1));
    await add(firstDay: 12);

    expect(
      [for (final report in await history.all()) report.id],
      ['id-2', 'id-1', 'id-0'],
    );
  });

  test('a failed write leaves no folder and no row', () async {
    // A directory where the PDF should go makes the write fail.
    Directory(
      '${support.path}/reports/id-0/'
      'pillpal-report-2026-10-10-2026-10-16.pdf',
    ).createSync(recursive: true);

    await expectLater(add(), throwsA(isA<FileSystemException>()));

    expect(folder('id-0').existsSync(), isFalse);
    expect(await history.all(), isEmpty);
  });

  test('reports made at the same instant list by id, newest id first',
      () async {
    await add();
    await add(firstDay: 11);

    expect(
      [for (final report in await history.all()) report.id],
      ['id-1', 'id-0'],
    );
  });

  group('limits', () {
    test('at 20 reports the oldest goes when a new one is made', () async {
      for (var i = 0; i < maxStoredReports; i++) {
        now = now.add(const Duration(minutes: 1));
        await add();
      }
      expect(await history.all(), hasLength(maxStoredReports));
      expect(folder('id-0').existsSync(), isTrue);

      now = now.add(const Duration(minutes: 1));
      final newest = await add();

      final kept = await history.all();
      expect(kept, hasLength(maxStoredReports));
      expect(kept.first.id, newest.id);
      expect(kept.map((r) => r.id), isNot(contains('id-0')));
      expect(folder('id-0').existsSync(), isFalse);
      expect(folder('id-1').existsSync(), isTrue);
    });

    test('reports older than 90 days are deleted at creation', () async {
      await add();
      now = now.add(storedReportRetention).add(const Duration(seconds: 1));

      final fresh = await add();

      expect([for (final r in await history.all()) r.id], [fresh.id]);
      expect(folder('id-0').existsSync(), isFalse);
    });

    test('a report exactly 90 days old is still kept', () async {
      await add();
      now = now.add(storedReportRetention);

      await history.reconcile();

      expect(await history.all(), hasLength(1));
    });
  });

  group('delete', () {
    test('removes the row and its folder, nothing else', () async {
      final first = await add();
      final second = await add(firstDay: 11);

      await history.delete(first.id);

      expect(await history.all(), [second]);
      expect(folder(first.id).existsSync(), isFalse);
      expect(folder(second.id).existsSync(), isTrue);
    });

    test('an unknown id is not an error', () async {
      await add();

      await history.delete('nope');

      expect(await history.all(), hasLength(1));
    });

    test('deleteAll removes every row and the whole reports folder', () async {
      await add();
      await add(firstDay: 11);
      File('${support.path}/reports/stray.pdf').writeAsBytesSync([1]);

      await history.deleteAll();

      expect(await history.all(), isEmpty);
      expect(Directory('${support.path}/reports').existsSync(), isFalse);
    });

    test('deleteAll with no folder does not fail', () async {
      await history.deleteAll();

      expect(await history.all(), isEmpty);
    });
  });

  group('reconcile', () {
    test('deletes rows without a file', () async {
      final report = await add();
      folder(report.id).deleteSync(recursive: true);

      await history.reconcile();

      expect(await history.all(), isEmpty);
    });

    test('deletes rows whose profile is gone, with their files', () async {
      final mine = await add();
      await _profile(db, 'p2');
      final relatives = await add(profileId: 'p2');
      await (db.delete(db.profiles)..where((p) => p.id.equals('p2'))).go();

      await history.reconcile();

      expect(await history.all(), [mine]);
      expect(folder(relatives.id).existsSync(), isFalse);
      expect(folder(mine.id).existsSync(), isTrue);
    });

    test('deletes the reports of a tombstoned profile', () async {
      final mine = await add();
      await _profile(db, 'p2');
      final relatives = await add(profileId: 'p2');
      await (db.update(db.profiles)..where((p) => p.id.equals('p2')))
          .write(const ProfilesCompanion(deletedAt: Value(5)));

      await history.reconcile();

      expect(await history.all(), [mine]);
      expect(folder(relatives.id).existsSync(), isFalse);
    });

    test('files of an evicted scope are removed as orphans', () async {
      await _profile(db, 'p2');
      final relatives = await add(profileId: 'p2');
      await db.evictScope('p2');
      expect(folder(relatives.id).existsSync(), isTrue);

      await history.reconcile();

      expect(folder(relatives.id).existsSync(), isFalse);
    });

    test('deletes folders and files that have no row', () async {
      final kept = await add();
      Directory('${support.path}/reports/orphan').createSync(recursive: true);
      File('${support.path}/reports/orphan/pillpal-report-x.pdf')
          .writeAsBytesSync([1]);
      File('${support.path}/reports/loose.pdf').writeAsBytesSync([1]);
      File('${folder(kept.id).path}/extra.pdf').writeAsBytesSync([1]);

      await history.reconcile();

      final root = Directory('${support.path}/reports');
      final names = [
        for (final entry in root.listSync(recursive: true))
          entry.uri.pathSegments.where((s) => s.isNotEmpty).last,
      ];
      expect(names, unorderedEquals([kept.id, _name(kept)]));
      expect(await history.all(), [kept]);
    });

    test('with nothing stored it does nothing', () async {
      await history.reconcile();

      expect(await history.all(), isEmpty);
    });

    test('does not delete the file of a report being added', () async {
      // Operations run one at a time, so reconcile cannot see the file
      // before its row exists.
      final adding = add();
      final reconciling = history.reconcile();
      final report = await adding;
      await reconciling;

      expect(await history.all(), [report]);
      expect(await (await history.fileOf(report)).exists(), isTrue);
    });
  });

  group('cascades of the database', () {
    test('wipeAccountData deletes every row', () async {
      await add();
      await add(firstDay: 11);

      await db.wipeAccountData();

      expect(await db.select(db.storedReports).get(), isEmpty);
    });

    test('evictScope deletes the rows of that profile only', () async {
      final mine = await add();
      await _profile(db, 'p2');
      await add(profileId: 'p2');

      await db.evictScope('p2');

      expect(await db.select(db.storedReports).get(), [mine]);
    });
  });
}

String _name(StoredReport report) =>
    'pillpal-report-${report.firstDay}-${report.lastDay}.pdf';

Future<void> _profile(AppDatabase db, String id) => db.into(db.profiles).insert(
      ProfileRow(
        id: id,
        kind: 'self',
        displayName: 'Test User',
        timezone: 'Europe/Samara',
        clientUpdatedAt: 1,
        updatedByDevice: 'd',
        missedAlertMinutes: 30,
        missedAlertsEnabled: true,
      ),
    );
