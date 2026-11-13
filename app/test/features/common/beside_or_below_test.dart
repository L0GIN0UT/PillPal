import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/features/common/beside_or_below.dart';

import 'common_test_host.dart';

// A title with its actions on narrow screens (docs/design.md, narrow screens
// 3). The test font draws every glyph 1 em wide: a 10 px title of N letters
// is N * 10 wide.

const Key _title = Key('title');
const Key _action = Key('action');

Widget _layout(
  String title, {
  double width = 200,
  bool below = false,
  TextDirection direction = TextDirection.ltr,
}) =>
    Directionality(
      textDirection: direction,
      child: SizedBox(
        width: width,
        child: BesideOrBelow(
          below: below,
          gap: 10,
          runGap: 4,
          main: Text(
            title,
            key: _title,
            style: const TextStyle(fontSize: 10, height: 1),
          ),
          trailing: const SizedBox.square(key: _action, dimension: 40),
        ),
      ),
    );

bool _beside(WidgetTester tester) =>
    tester.getTopLeft(find.byKey(_action)).dy <
    tester.getBottomLeft(find.byKey(_title)).dy;

void main() {
  testWidgets('a title that fits beside keeps the action on its line',
      (tester) async {
    await pumpThemed(tester, _layout('Medications'));

    expect(_beside(tester), isTrue);
    // The action at the end, the title takes the rest.
    expect(tester.getTopRight(find.byKey(_action)).dx, 200);
    expect(tester.getSize(find.byKey(_title)).width, 200 - 10 - 40);
  });

  testWidgets('a title that fits only alone puts the action under it',
      (tester) async {
    // 16 letters: 160 fits 200, not 200 - 10 - 40.
    await pumpThemed(tester, _layout('Abcdefghijklmnop'));

    expect(_beside(tester), isFalse);
    expect(
      tester.getTopLeft(find.byKey(_action)).dy,
      tester.getBottomLeft(find.byKey(_title)).dy + 4,
    );
    expect(tester.getTopRight(find.byKey(_action)).dx, 200);
    expect(tester.getSize(find.byKey(_title)).width, 200);
  });

  testWidgets('a word that breaks only beside puts the action under it',
      (tester) async {
    // The 16-letter word fits 200 alone; the line wraps either way.
    await pumpThemed(tester, _layout('Abcdefghijklmnop and more words'));

    expect(_beside(tester), isFalse);
  });

  testWidgets('a word too long for the line anyway keeps the action beside',
      (tester) async {
    // 25 letters do not fit 200 even alone: moving the action helps nothing.
    await pumpThemed(tester, _layout('Abcdefghijklmnopqrstuvwxy'));

    expect(_beside(tester), isTrue);
  });

  testWidgets('below puts the action under the title whatever the width',
      (tester) async {
    await pumpThemed(tester, _layout('Short', below: true));

    expect(_beside(tester), isFalse);
  });

  testWidgets('right to left: the action at the left end', (tester) async {
    await pumpThemed(
      tester,
      _layout('Short', direction: TextDirection.rtl),
    );
    expect(tester.getTopLeft(find.byKey(_action)).dx, 0);

    await pumpThemed(
      tester,
      _layout('Abcdefghijklmnop', direction: TextDirection.rtl),
    );
    expect(_beside(tester), isFalse);
    expect(tester.getTopLeft(find.byKey(_action)).dx, 0);
  });

  testWidgets('the action stays tappable in both layouts', (tester) async {
    var taps = 0;
    Widget layout(String title) => SizedBox(
          width: 200,
          child: BesideOrBelow(
            main: Text(title, style: const TextStyle(fontSize: 10)),
            trailing: IconButton(
              key: _action,
              onPressed: () => taps++,
              icon: const Icon(Icons.add),
            ),
          ),
        );

    await pumpThemed(tester, layout('Short'));
    await tester.tap(find.byKey(_action));
    await pumpThemed(tester, layout('Abcdefghijklmnop'));
    await tester.tap(find.byKey(_action));

    expect(taps, 2);
  });

  testWidgets('intrinsic sizes follow the two layouts', (tester) async {
    await pumpThemed(tester, _layout('Medications'));
    final render = tester.renderObject<RenderBesideOrBelow>(
      find.byType(BesideOrBelow),
    );

    // One line: title 110, gap 10, action 40.
    expect(render.getMaxIntrinsicWidth(double.infinity), 160);
    // The widest unbreakable part: the 11-letter word.
    expect(render.getMinIntrinsicWidth(double.infinity), 110);
    // Beside at 200: as high as the action.
    expect(render.getMinIntrinsicHeight(200), 40);
    // At 120 the title fits only alone: title, run gap, action.
    expect(render.getMinIntrinsicHeight(120), 10 + 4 + 40);
  });

  testWidgets('the dry layout matches the real one', (tester) async {
    for (final title in ['Medications', 'Abcdefghijklmnop']) {
      await pumpThemed(tester, _layout(title));
      final render = tester.renderObject<RenderBesideOrBelow>(
        find.byType(BesideOrBelow),
      );
      expect(
        render.getDryLayout(const BoxConstraints.tightFor(width: 200)),
        render.size,
        reason: title,
      );
    }
  });

  testWidgets('below, the title is read before the action', (tester) async {
    final handle = tester.ensureSemantics();
    const group = Key('group');
    await pumpThemed(
      tester,
      Semantics(
        key: group,
        container: true,
        explicitChildNodes: true,
        child: SizedBox(
          width: 200,
          child: BesideOrBelow(
            main: Semantics(
              container: true,
              child: const Text(
                'Abcdefghijklmnop',
                style: TextStyle(fontSize: 10),
              ),
            ),
            trailing: Semantics(
              container: true,
              label: 'Act',
              child: const SizedBox.square(dimension: 40),
            ),
          ),
        ),
      ),
    );
    final labels = tester
        .getSemantics(find.byKey(group))
        .debugListChildrenInOrder(DebugSemanticsDumpOrder.traversalOrder)
        .map((node) => node.label)
        .toList();

    expect(labels, ['Abcdefghijklmnop', 'Act']);
    handle.dispose();
  });
}
