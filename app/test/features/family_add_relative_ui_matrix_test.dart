import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/features/catalog/scanner_adapter.dart';
import 'package:pillpal/src/features/common/pillpal_check_tile.dart';
import 'package:pillpal/src/features/doses/dose_providers.dart';
import 'package:pillpal/src/features/family/add_relative_screen.dart';
import 'package:pillpal/src/features/family/invite_code_view.dart';
import 'package:pillpal/src/features/family/invite_scan_sheet.dart';
import 'package:pillpal/src/features/family/relative_added_view.dart';

import '../support/family_matrix.dart';
import '../support/ui_matrix.dart';
import 'fake_scanner.dart';

// «Добавить близкого» in the whole UI matrix: the role and disclosure step,
// the QR panel (live, expired, failed), the success view and the scanner.

/// A camera that reports [failure] as the sheet listens.
class _FailedScanner extends FakeScannerAdapter {
  _FailedScanner(this.failure);

  final ScannerFailure failure;

  @override
  Stream<ScannerFailure> get failures => Stream.value(failure);
}

Widget _roleBox() => PillPalCheckTile(
      tileKey: const Key('add-relative-editor'),
      value: true,
      title: 'Can change my medications',
      subtitle: 'Sees "Family" medications and can change them.',
      onChanged: (_) {},
    );

void main() {
  testWidgets('Add relative (role and disclosure) in the matrix',
      (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => familyMatrixScope(
        const AddRelativeScreen(),
        [
          selfProfileProvider.overrideWith(
            (ref) => Stream.value(matrixOwn.profile),
          ),
        ],
      ),
      expectTouchTargets: true,
      check: (tester, cell) => expectMatrixKeys(tester, cell, const [
        Key('add-relative-editor'),
        Key('invite-disclosure'),
        Key('add-relative-show-code'),
        Key('add-relative-scan'),
        Key('add-relative-managed'),
      ]),
    );
  });

  testWidgets('Invite code (live, expired, failed) in the matrix',
      (tester) async {
    const expected = {
      InviteCodeArea.code: [
        Key('invite-qr'),
        Key('invite-countdown'),
        Key('invite-share'),
      ],
      InviteCodeArea.expired: [Key('invite-expired'), Key('invite-refresh')],
      InviteCodeArea.failed: [Key('invite-error'), Key('invite-retry')],
    };
    for (final entry in expected.entries) {
      await pumpUiMatrix(
        tester,
        (context) => matrixScrolling(
          InviteCodeView(
            area: entry.key,
            url:
                'https://links-ru.pillpal.invalid/i#abcdefghijklmnopqrstuvwxyz',
            left: () => const Duration(minutes: 14, seconds: 5),
            errorText: 'The limit of relatives has been reached.',
            onShare: () {},
            onRefresh: () {},
            belowCode: _roleBox(),
            secondaryAction: OutlinedButton(
              key: const Key('add-relative-done'),
              onPressed: () {},
              child: const Text('Done'),
            ),
          ),
        ),
        expectTouchTargets: true,
        check: (tester, cell) => expectMatrixKeys(tester, cell, [
          const Key('add-relative-editor'),
          const Key('add-relative-done'),
          ...entry.value,
        ]),
      );
    }
  });

  testWidgets('Relative added (named and not) in the matrix', (tester) async {
    for (final accepted in const [
      AcceptedRelative(
        role: 'editor',
        linkId: 'out-1',
        name: 'Alex Relative With A Long Name',
      ),
      AcceptedRelative(role: 'viewer'),
    ]) {
      await pumpUiMatrix(
        tester,
        (context) => familyMatrixScope(
          matrixScrolling(
            RelativeAddedView(accepted: accepted, onDone: () {}),
          ),
        ),
        expectTouchTargets: true,
        check: (tester, cell) => expectMatrixKeys(tester, cell, [
          const Key('relative-added'),
          const Key('relative-added-role'),
          const Key('relative-added-done'),
          if (accepted.linkId != null) const Key('relative-added-revoke'),
        ]),
      );
    }
  });

  testWidgets('Invite scanner (camera, refused, unavailable) in the matrix',
      (tester) async {
    final notices = <ScannerFailure?, Key>{
      null: const Key('invite-scan-hint'),
      ScannerFailure.permissionDenied:
          const Key('invite-scan-notice-permission'),
      ScannerFailure.unavailable: const Key('invite-scan-notice-unavailable'),
    };
    for (final entry in notices.entries) {
      final failure = entry.key;
      await pumpUiMatrix(
        tester,
        (context) => familyMatrixScope(
          const Material(child: InviteScanSheet()),
          [
            inviteScannerFactoryProvider.overrideWithValue(
              () => failure == null
                  ? FakeScannerAdapter()
                  : _FailedScanner(failure),
            ),
          ],
        ),
        expectTouchTargets: true,
        check: (tester, cell) async {
          await tester.pump();
          await expectMatrixKeys(tester, cell, [
            const Key('invite-scan-paste'),
            const Key('invite-scan-close'),
            entry.value,
          ]);
        },
      );
    }
  });
}
