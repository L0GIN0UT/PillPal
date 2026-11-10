import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/common/profile_chips.dart';
import 'package:pillpal/src/theme/sizes.dart';

import '../../support/ui_matrix.dart';
import 'common_test_host.dart';

List<ProfileChipItem> _profiles(int count, {bool long = false}) => [
      for (var i = 1; i <= count; i++)
        ProfileChipItem(
          id: 'p$i',
          label: long ? 'Профиль номер $i' : 'P$i',
        ),
    ];

Widget _chips(
  List<ProfileChipItem> profiles, {
  String selected = 'p1',
  ValueChanged<String>? onSelected,
}) =>
    ProfileChips(
      profiles: profiles,
      selectedId: selected,
      onSelected: onSelected ?? (_) {},
    );

Finder _chip(String id) => find.byKey(ValueKey('profile-switch-$id'));

final Finder _all = find.byKey(const Key('profile-chips-all'));
final Finder _fade = find.byKey(const Key('profile-chips-fade'));

void main() {
  testWidgets('up to four profiles are all visible, with no «All» chip',
      (tester) async {
    await pumpThemed(tester, _chips(_profiles(4)));
    for (final id in ['p1', 'p2', 'p3', 'p4']) {
      expect(_chip(id), findsOneWidget);
    }
    expect(_all, findsNothing);
  });

  testWidgets('more than four show four and a pinned «All N» chip',
      (tester) async {
    await pumpThemed(tester, _chips(_profiles(6)));
    expect(
        find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('profile-switch-'),
        ),
        findsNWidgets(ProfileChips.maxVisible));
    expect(_chip('p5'), findsNothing);
    expect(find.descendant(of: _all, matching: find.text('All 6')),
        findsOneWidget);
  });

  testWidgets('the selected chip is first', (tester) async {
    await pumpThemed(tester, _chips(_profiles(6), selected: 'p5'));
    expect(_chip('p5'), findsOneWidget);
    final selectedX = tester.getTopLeft(_chip('p5')).dx;
    for (final id in ['p1', 'p2', 'p3']) {
      expect(tester.getTopLeft(_chip(id)).dx, greaterThan(selectedX));
    }
    expect(_chip('p4'), findsNothing);
  });

  testWidgets('the selected chip shows a check, the others do not',
      (tester) async {
    await pumpThemed(tester, _chips(_profiles(3), selected: 'p2'));
    expect(
      find.descendant(of: _chip('p2'), matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: _chip('p1'), matching: find.byIcon(Icons.check)),
      findsNothing,
    );
  });

  testWidgets('tapping a chip selects it', (tester) async {
    String? picked;
    await pumpThemed(
      tester,
      _chips(_profiles(3), onSelected: (id) => picked = id),
    );
    await tester.tap(_chip('p3'));
    expect(picked, 'p3');
  });

  testWidgets('«All N» opens the sheet with every profile', (tester) async {
    String? picked;
    await pumpThemed(
      tester,
      _chips(_profiles(6), onSelected: (id) => picked = id),
    );
    await tester.tap(_all);
    await tester.pumpAndSettle();
    expect(find.text('Profiles'), findsOneWidget);
    for (var i = 1; i <= 6; i++) {
      expect(find.byKey(ValueKey('profile-sheet-p$i')), findsOneWidget);
    }
    await tester.tap(find.byKey(const ValueKey('profile-sheet-p6')));
    await tester.pumpAndSettle();
    expect(picked, 'p6');
    expect(find.text('Profiles'), findsNothing);
  });

  testWidgets('fades the end of the row only while it scrolls', (tester) async {
    await pumpThemed(
      tester,
      _chips(_profiles(5, long: true)),
      size: const Size(320, 568),
    );
    await tester.pump();
    expect(_fade, findsOneWidget);
    expect(
      tester.getSize(_fade).width,
      PillPalSizes.chipFade,
    );
    await pumpThemed(tester, _chips(_profiles(2)));
    await tester.pump();
    expect(_fade, findsNothing);
  });

  testWidgets('chips are 44 high, 64 in senior mode', (tester) async {
    await pumpThemed(tester, _chips(_profiles(3)));
    expect(tester.getSize(_chip('p1')).height, PillPalSizes.profileChip);
    await pumpThemed(tester, _chips(_profiles(3)), senior: true);
    expect(
      tester.getSize(_chip('p1')).height,
      PillPalSizes.seniorButtonHeight,
    );
  });

  testWidgets('chips are selectable buttons for screen readers',
      (tester) async {
    final handle = tester.ensureSemantics();
    await pumpThemed(tester, _chips(_profiles(3), selected: 'p2'));
    expect(
      tester.getSemantics(_chip('p2')),
      matchesSemantics(
        label: 'P2',
        isButton: true,
        isSelected: true,
        hasSelectedState: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('fits 320 px at text x2.0 in Russian, in the whole matrix',
      (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => SizedBox(
        width: MediaQuery.sizeOf(context).width,
        child: _chips(_profiles(7, long: true), selected: 'p3'),
      ),
      expectTouchTargets: true,
    );
  });

  testWidgets('cuts a long name with an ellipsis, the label stays whole',
      (tester) async {
    final handle = tester.ensureSemantics();
    const name = 'Очень длинное имя профиля которое не помещается в чип';
    await pumpThemed(
      tester,
      _chips(const [
        ProfileChipItem(id: 'p1', label: name),
        ProfileChipItem(id: 'p2', label: 'B'),
      ]),
    );
    expect(
        tester.widget<Text>(find.text(name)).overflow, TextOverflow.ellipsis);
    expect(
      tester.getSize(find.text(name)).width,
      lessThanOrEqualTo(PillPalSizes.chipLabelMaxWidth),
    );
    expect(find.bySemanticsLabel(name), findsOneWidget);
    handle.dispose();
  });

  testWidgets('the check of the selected chip is the chip icon size',
      (tester) async {
    await pumpThemed(tester, _chips(_profiles(3)));
    expect(
      tester.widget<Icon>(find.byIcon(Icons.check)).size,
      PillPalSizes.chipIcon,
    );
  });

  testWidgets('selecting a chip scrolls the row back to the selected one',
      (tester) async {
    final selected = ValueNotifier('p1');
    await pumpThemed(
      tester,
      ValueListenableBuilder<String>(
        valueListenable: selected,
        builder: (_, id, __) => _chips(
          _profiles(4, long: true),
          selected: id,
          onSelected: (v) => selected.value = v,
        ),
      ),
      size: const Size(320, 568),
    );
    await tester.drag(
      find.byType(SingleChildScrollView).last,
      const Offset(-300, 0),
    );
    await tester.pump();
    selected.value = 'p4';
    await tester.pumpAndSettle();
    final rect = tester.getRect(_chip('p4'));
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(320));
  });

  testWidgets('the selected row of the All sheet is marked selected',
      (tester) async {
    await pumpThemed(tester, _chips(_profiles(6), selected: 'p2'));
    await tester.tap(_all);
    await tester.pumpAndSettle();
    ListTile row(String id) =>
        tester.widget<ListTile>(find.byKey(ValueKey('profile-sheet-$id')));
    expect(row('p2').selected, isTrue);
    expect(row('p3').selected, isFalse);
  });

  // The text under the fade is meant to fade, so this matrix measures a row
  // that fits and has none.
  testWidgets('reads well in the whole matrix when it fits', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => SizedBox(
        width: MediaQuery.sizeOf(context).width,
        child: _chips(_profiles(3), selected: 'p2'),
      ),
      expectTouchTargets: true,
      expectContrast: true,
    );
  });
}
