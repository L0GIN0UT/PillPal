import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/features/report/report_actions.dart';
import 'package:pillpal/src/features/report/report_history.dart';
import 'package:pillpal_core/pillpal_core.dart';

/// The Android side of the report file actions: the Dart half of the
/// `pillpal/reports` channel (docs/adr/0019 §5), against a mock handler.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late AppDatabase db;
  late Directory support;
  late ReportHistory history;
  late ChannelReportActions actions;
  late StoredReport report;
  final calls = <MethodCall>[];

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    db = AppDatabase(NativeDatabase.memory());
    support = Directory.systemTemp.createTempSync('pillpal-actions-');
    history = ReportHistory(
      db: db,
      supportDirectory: () async => support,
      clock: () => DateTime.utc(2026, 10, 16, 10),
      newId: () => 'r1',
    );
    actions = ChannelReportActions(reportChannel, history);
    report = await history.add(
      profileId: 'p1',
      range: (first: LocalDate(2026, 10, 10), last: LocalDate(2026, 10, 16)),
      includeHidden: true,
      bytes: Uint8List.fromList(const [1, 2, 3]),
    );
    calls.clear();
    addTearDown(() async {
      messenger.setMockMethodCallHandler(reportChannel, null);
      await db.close();
      support.deleteSync(recursive: true);
    });
  });

  void answer(Future<Object?> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(reportChannel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  test('each action calls its method with the stored file path only', () async {
    answer((call) async => 'done');
    final file = await history.fileOf(report);

    expect(await actions.open(report), ReportActionResult.done);
    expect(await actions.save(report), ReportActionResult.done);
    expect(await actions.share(report), ReportActionResult.done);

    expect(
        [for (final call in calls) call.method], ['open', 'saveAs', 'share']);
    for (final call in calls) {
      // Nothing but the path crosses: no name, no profile, no dates.
      expect(call.arguments, {'path': file.path});
    }
    expect(
      file.path.replaceAll(r'\', '/'),
      endsWith('/reports/r1/pillpal-report-2026-10-10-2026-10-16.pdf'),
    );
  });

  test('a closed save picker is "cancelled"', () async {
    answer((call) async => 'cancelled');

    expect(await actions.save(report), ReportActionResult.cancelled);
  });

  test('no viewer is "noApp"', () async {
    answer((call) async => 'no_app');

    expect(await actions.open(report), ReportActionResult.noApp);
  });

  test('a second call while one waits is "busy", not an error', () async {
    answer((call) async => throw PlatformException(code: 'busy'));

    expect(await actions.share(report), ReportActionResult.busy);
  });

  test('other native errors reach the caller', () async {
    answer((call) async => throw PlatformException(code: 'io_error'));

    await expectLater(
      actions.save(report),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'io_error'),
      ),
    );
  });

  test('an invalid path is an error too', () async {
    answer((call) async => throw PlatformException(code: 'invalid_path'));

    await expectLater(actions.open(report), throwsA(isA<PlatformException>()));
  });
}
