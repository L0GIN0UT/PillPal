import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/common/person_row.dart';
import 'package:pillpal/src/features/common/pillpal_icon_button.dart';
import 'package:pillpal/src/features/common/status_kind.dart';
import 'package:pillpal/src/features/common/status_pill.dart';
import 'package:pillpal/src/theme/sizes.dart';

import '../../support/ui_matrix.dart';
import 'common_test_host.dart';

// The avatar row shared by Family and the invite and relative screens.

const _rowKey = ValueKey('row');

Widget _row({VoidCallback? onTap, bool action = false}) => PillPalPersonRow(
      rowKey: _rowKey,
      name: 'Grace Longname',
      subtitle: 'Viewer',
      status: const StatusPill(StatusKind.inactive, label: 'Paused'),
      chevron: true,
      onTap: onTap ?? () {},
      action: action
          ? PillPalIconButton(
              tooltip: 'Settings',
              onPressed: () {},
              icon: Icons.tune,
            )
          : null,
    );

void main() {
  testWidgets('is at least 72 high and the avatar is 48', (tester) async {
    await pumpThemed(tester, _row());

    expect(
      tester.getSize(find.byKey(_rowKey)).height,
      greaterThanOrEqualTo(PillPalSizes.personRowMin),
    );
    expect(
      tester.getSize(find.byKey(const Key('person-avatar'))),
      const Size.square(PillPalSizes.avatarMd),
    );
  });

  testWidgets('the name is in 600, the initial in 700', (tester) async {
    await pumpThemed(tester, _row());

    expect(
      tester.widget<Text>(find.text('Grace Longname')).style?.fontWeight,
      FontWeight.w600,
    );
    expect(
      tester.widget<Text>(find.text('G')).style?.fontWeight,
      FontWeight.w700,
    );
  });

  testWidgets('reads as one button: name, role and status; action apart',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpThemed(tester, _row(action: true));

    final node = tester.getSemantics(
      find.descendant(
        of: find.byType(PillPalPersonRow),
        matching: find.byType(MergeSemantics),
      ),
    );
    final data = node.getSemanticsData();
    expect(data.label, contains('Grace Longname'));
    expect(data.label, contains('Viewer'));
    expect(data.label, contains('Paused'));
    expect(data.flagsCollection.isButton, isTrue);
    // The initial is decoration, not read out.
    expect(node.label, isNot(contains('\nG\n')));
    // The action is its own node, not part of the row.
    final action = tester.getSemantics(find.byTooltip('Settings'));
    expect(action.label, isNot(contains('Grace Longname')));
    semantics.dispose();
  });

  testWidgets('a tap calls onTap', (tester) async {
    var taps = 0;
    await pumpThemed(tester, _row(onTap: () => taps++));

    await tester.tap(find.byKey(_rowKey));

    expect(taps, 1);
  });

  testWidgets('in the whole matrix: targets and contrast', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => SingleChildScrollView(
        child: Column(children: [_row(action: true), _row()]),
      ),
      expectTouchTargets: true,
      expectContrast: true,
    );
  });
}
