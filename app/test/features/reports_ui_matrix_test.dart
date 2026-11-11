import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/features/family/profile_context.dart';
import 'package:pillpal/src/features/report/report_actions.dart';
import 'package:pillpal/src/features/report/report_history.dart';
import 'package:pillpal/src/features/report/report_ready_view.dart';
import 'package:pillpal/src/features/report/reports_screen.dart';

import '../support/ui_matrix.dart';
import 'report_fakes.dart';

// «Отчёт готов» (B2-ReportReady) and «Мои отчёты» (B2-MyReports) in the
// whole UI matrix: light/dark, normal/senior, RU/EN, text scale 1 and 2, two
// sizes. No overflow, touch targets of the mode, contrast of the texts.

const StoredReport _newer = StoredReport(
  id: 'report-1',
  profileId: 'profile-1',
  firstDay: '2026-10-01',
  lastDay: '2026-10-31',
  includeHidden: true,
  createdAt: 1789000000000000,
  sizeBytes: 126000,
);

const StoredReport _older = StoredReport(
  id: 'report-2',
  profileId: 'profile-1',
  firstDay: '2026-09-12',
  lastDay: '2026-10-11',
  includeHidden: false,
  createdAt: 1788000000000000,
  sizeBytes: 1800000,
);

/// A history that only reconciles (nothing): the screen reads the list from
/// [storedReportsProvider], which the test overrides.
class _QuietHistory implements ReportHistory {
  @override
  Future<void> reconcile() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _scope(Widget app, List<StoredReport> reports) {
  return ProviderScope(
    key: UniqueKey(),
    overrides: [
      storedReportsProvider.overrideWith((ref) => Stream.value(reports)),
      accessibleProfilesProvider.overrideWith((ref) => Stream.value(const [])),
      reportHistoryProvider.overrideWithValue(_QuietHistory()),
      reportActionsProvider.overrideWithValue(FakeReportActions()),
    ],
    child: app,
  );
}

Widget _screenSized(BuildContext context, Widget child) => SizedBox(
      width: MediaQuery.sizeOf(context).width,
      height: MediaQuery.sizeOf(context).height,
      child: child,
    );

void main() {
  testWidgets('the ready state holds in the whole matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screenSized(context, const ReportReadyView(report: _newer)),
      wrap: (app) => _scope(app, [_newer, _older]),
      expectTouchTargets: true,
      expectContrast: true,
      check: (tester, cell) async {
        await tester.pump();
        for (final key in [
          'report-ready-title',
          'report-open',
          'report-save',
          'report-share',
          'report-leaves-control',
          'report-history',
        ]) {
          expect(
            find.byKey(Key(key)),
            findsOneWidget,
            reason: '"$key" is missing in "${cell.label}"',
          );
        }
      },
    );
  });

  testWidgets('the list holds in the whole matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screenSized(context, const ReportsScreen()),
      wrap: (app) => _scope(app, [_newer, _older]),
      expectTouchTargets: true,
      expectContrast: true,
      check: (tester, cell) async {
        await tester.pump();
        // A page tall enough to build the whole list: at the compact scale
        // the delete-all button is its last child.
        tester.view.physicalSize = Size(cell.size.width, 20000);
        await tester.pump();
        for (final key in [
          'reports-list',
          'reports-delete-all',
          'report-item-report-1',
          'report-item-menu-report-1',
          'report-item-report-2',
        ]) {
          expect(
            find.byKey(
              key.startsWith('report-item') ? ValueKey(key) : Key(key),
            ),
            findsOneWidget,
            reason: '"$key" is missing in "${cell.label}"',
          );
        }
      },
    );
  });

  testWidgets('the empty list holds in the whole matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screenSized(context, const ReportsScreen()),
      wrap: (app) => _scope(app, const []),
      expectTouchTargets: true,
      check: (tester, cell) async {
        await tester.pump();
        expect(
          find.byKey(const Key('reports-empty')),
          findsOneWidget,
          reason: 'the empty note is missing in "${cell.label}"',
        );
      },
    );
  });
}
