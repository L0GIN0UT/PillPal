import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/sync/sync_status.dart';
import 'package:pillpal/src/features/report/report_history.dart';
import 'package:pillpal/src/features/report/report_scope.dart';
import 'package:pillpal_core/pillpal_core.dart';

/// A sync status the test sets by hand.
class _FakeSyncStatus extends SyncStatusNotifier {
  @override
  SyncStatus build() => const SyncStatus();

  void set(SyncStatus status) => state = status;
}

void main() {
  late AppDatabase db;
  late Directory support;
  late ReportHistory history;
  late int counter;

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    db = AppDatabase(NativeDatabase.memory());
    support = Directory.systemTemp.createTempSync('pillpal-scope-');
    counter = 0;
    history = ReportHistory(
      db: db,
      supportDirectory: () async => support,
      clock: () => DateTime.utc(2026, 10, 16, 10),
      newId: () => 'id-${counter++}',
    );
    addTearDown(() async {
      await db.close();
      support.deleteSync(recursive: true);
    });
    await db.into(db.profiles).insert(
          const ProfileRow(
            id: 'p1',
            kind: 'self',
            displayName: 'Test User',
            timezone: 'Europe/Samara',
            clientUpdatedAt: 1,
            updatedByDevice: 'd',
            missedAlertMinutes: 30,
            missedAlertsEnabled: true,
          ),
        );
  });

  Future<StoredReport> add() => history.add(
        profileId: 'p1',
        range: (first: LocalDate(2026, 10, 10), last: LocalDate(2026, 10, 16)),
        includeHidden: true,
        bytes: Uint8List.fromList(const [1]),
      );

  Future<ProviderContainer> pumpScope(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        reportHistoryProvider.overrideWithValue(history),
        syncStatusProvider.overrideWith(_FakeSyncStatus.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const ReportScope(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(),
          ),
        ),
      ),
    );
    return container;
  }

  /// Lets the real file and database work of the scope finish.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
    }
  }

  testWidgets('reconciles at start: a report without a file is dropped',
      (tester) async {
    final report = (await tester.runAsync(add))!;
    Directory('${support.path}/reports/${report.id}')
        .deleteSync(recursive: true);

    await pumpScope(tester);
    var rows = 1;
    for (var i = 0; i < 100 && rows > 0; i++) {
      await settle(tester, () => false);
      rows = (await tester.runAsync(() => history.all()))!.length;
    }

    expect(rows, 0);
  });

  for (final failed in [false, true]) {
    testWidgets(
        'reconciles at the end of a ${failed ? 'failed' : 'successful'} run: '
        'the file of an evicted scope goes', (tester) async {
      final report = (await tester.runAsync(add))!;
      final container = await pumpScope(tester);
      final folder = Directory('${support.path}/reports/${report.id}');
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      expect(folder.existsSync(), isTrue, reason: 'a live scope keeps it');

      // The pull evicted the scope (rows go with it); the file stays.
      await tester.runAsync(() => db.evictScope('p1'));
      final status =
          container.read(syncStatusProvider.notifier) as _FakeSyncStatus;
      status.set(const SyncStatus(phase: SyncPhase.syncing));
      status.set(
        failed
            ? const SyncStatus(phase: SyncPhase.error, errorCode: 'network')
            : SyncStatus(lastSuccessAt: DateTime.utc(2026, 10, 16, 11)),
      );
      await settle(tester, () => !folder.existsSync());

      expect(folder.existsSync(), isFalse);
    });
  }

  testWidgets('a status change that is not the end of a run does nothing',
      (tester) async {
    final report = (await tester.runAsync(add))!;
    final container = await pumpScope(tester);
    await tester.runAsync(() => db.evictScope('p1'));

    (container.read(syncStatusProvider.notifier) as _FakeSyncStatus)
        .set(const SyncStatus(phase: SyncPhase.syncing));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );

    expect(
      Directory('${support.path}/reports/${report.id}').existsSync(),
      isTrue,
    );
  });
}
