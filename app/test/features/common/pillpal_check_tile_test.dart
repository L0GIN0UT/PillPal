import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/features/common/pillpal_check_tile.dart';

import '../../support/ui_matrix.dart';

void main() {
  testWidgets('the footer starts where the label starts, in every mode',
      (tester) async {
    var ticked = false;
    await pumpUiMatrix(
      tester,
      (context) => StatefulBuilder(
        builder: (context, setState) => SingleChildScrollView(
          child: PillPalCheckTile(
            tileKey: const Key('tile'),
            value: ticked,
            onChanged: (value) => setState(() => ticked = value),
            title: 'Synthetic label',
            subtitle: 'Synthetic explanation',
            footer: const [Text('Synthetic link')],
          ),
        ),
      ),
      check: (tester, cell) async {
        final label = tester.getTopLeft(find.text('Synthetic label')).dx;
        final footer = tester.getTopLeft(find.text('Synthetic link')).dx;
        expect(footer, closeTo(label, 0.5), reason: cell.label);
        await tester.tap(find.byKey(const Key('tile')));
        await tester.pump();
        expect(ticked, isTrue, reason: cell.label);
        ticked = false;
      },
    );
  });

  testWidgets('a tile without a handler is inert', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => const PillPalCheckTile(
        tileKey: Key('tile'),
        value: false,
        onChanged: null,
        title: 'Synthetic label',
      ),
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async {
        final tile =
            tester.widget<CheckboxListTile>(find.byKey(const Key('tile')));
        expect(tile.onChanged, isNull);
      },
    );
  });
}
