import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/features/report/report_actions.dart';
import 'package:pillpal/src/features/report/report_history.dart';
import 'package:pillpal_core/pillpal_core.dart';

/// A [ReportActions] that records what it was asked and answers as told.
class FakeReportActions implements ReportActions {
  /// `open:<id>`, `save:<id>`, `share:<id>` in call order.
  final List<String> calls = [];

  /// The answer per method name (`open`, `save`, `share`); default `done`.
  final Map<String, ReportActionResult> results = {};

  /// When set, every call throws it (a failed copy, an invalid path).
  Object? failure;

  Future<ReportActionResult> _answer(String method, StoredReport report) async {
    calls.add('$method:${report.id}');
    final error = failure;
    if (error != null) {
      throw error;
    }
    return results[method] ?? ReportActionResult.done;
  }

  @override
  Future<ReportActionResult> open(StoredReport report) =>
      _answer('open', report);

  @override
  Future<ReportActionResult> save(StoredReport report) =>
      _answer('save', report);

  @override
  Future<ReportActionResult> share(StoredReport report) =>
      _answer('share', report);
}

/// Lets real file and timer work finish under the widget test's fake clock.
Future<void> settleReal(WidgetTester tester, {int rounds = 12}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Keeps a one-day report of [profileId] through the real history (a file in
/// the harness's temp folder and a row), made at [createdAt].
Future<StoredReport> keepReport(
  WidgetTester tester,
  ProviderContainer container, {
  required String profileId,
  required int day,
  DateTime? createdAt,
}) async {
  final history = container.read(reportHistoryProvider);
  final report = await tester.runAsync(
    () => history.add(
      profileId: profileId,
      range: (first: LocalDate(2026, 10, day), last: LocalDate(2026, 10, day)),
      includeHidden: true,
      bytes: Uint8List.fromList(List<int>.filled(2048, 7)),
    ),
  );
  if (report == null) {
    throw StateError('The report was not kept');
  }
  if (createdAt != null) {
    // Distinct creation times fix the newest-first order.
    await container.read(databaseProvider).customStatement(
      'UPDATE stored_reports SET created_at = ? WHERE id = ?',
      [createdAt.microsecondsSinceEpoch, report.id],
    );
  }
  return report;
}

/// Whether the stored PDF of [report] is on disk.
Future<bool> fileExists(
  WidgetTester tester,
  ProviderContainer container,
  StoredReport report,
) async {
  final history = container.read(reportHistoryProvider);
  return await tester.runAsync(
        () async => (await history.fileOf(report)).exists(),
      ) ??
      false;
}
