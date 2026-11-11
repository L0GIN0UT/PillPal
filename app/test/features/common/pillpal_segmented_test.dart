import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/features/common/pillpal_segmented.dart';
import 'package:pillpal/src/theme/sizes.dart';

import '../../support/ui_matrix.dart';
import 'common_test_host.dart';

enum _Level { quiet, normal, persistent }

Key _keyOf(_Level level) => ValueKey('reminder-level-${level.name}');

Widget _segmented(
  Map<_Level, String> options, {
  _Level selected = _Level.normal,
  ValueChanged<_Level>? onChanged,
}) =>
    SizedBox(
      width: double.infinity,
      child: PillPalSegmented<_Level>(
        options: options,
        selected: selected,
        onChanged: onChanged ?? (_) {},
        keyOf: _keyOf,
      ),
    );

// Short: the test font draws every letter 1 em wide.
const _short = {
  _Level.quiet: 'Low',
  _Level.normal: 'Mid',
  _Level.persistent: 'High',
};

const _long = {
  _Level.quiet: 'Тихо и без звука для ночи',
  _Level.normal: 'Обычно со звуком уведомления',
  _Level.persistent: 'Настойчиво до отметки приёма',
};

void main() {
  testWidgets('short labels stay a segmented control', (tester) async {
    await pumpThemed(tester, _segmented(_short));
    expect(find.byType(SegmentedButton<_Level>), findsOneWidget);
    expect(find.byKey(const Key('segmented-radio-list')), findsNothing);
  });

  testWidgets('draws a raised stadium track', (tester) async {
    await pumpThemed(tester, _segmented(_short));
    final box = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(PillPalSegmented<_Level>),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final shape = (box.decoration as ShapeDecoration);
    expect(shape.color, paletteOf().raised);
    expect(shape.shape, isA<StadiumBorder>());
  });

  testWidgets('every option carries its key and a tap picks it',
      (tester) async {
    _Level? picked;
    await pumpThemed(tester, _segmented(_short, onChanged: (v) => picked = v));
    for (final level in _Level.values) {
      expect(find.byKey(_keyOf(level)), findsOneWidget);
    }
    await tester.tap(find.byKey(_keyOf(_Level.persistent)));
    expect(picked, _Level.persistent);
  });

  testWidgets('falls back to a radio list in RU at 320 px and text x2.0',
      (tester) async {
    _Level? picked;
    await pumpThemed(
      tester,
      _segmented(_long, onChanged: (v) => picked = v),
      locale: const Locale('ru'),
      scale: 2,
      size: const Size(320, 568),
    );
    expect(find.byType(SegmentedButton<_Level>), findsNothing);
    expect(find.byKey(const Key('segmented-radio-list')), findsOneWidget);
    expect(tester.takeException(), isNull);
    for (final level in _Level.values) {
      expect(find.byKey(_keyOf(level)), findsOneWidget);
    }
    await tester.tap(find.byKey(_keyOf(_Level.quiet)));
    expect(picked, _Level.quiet);
  });

  testWidgets('the radio list marks the selected option as checked',
      (tester) async {
    final handle = tester.ensureSemantics();
    await pumpThemed(
      tester,
      _segmented(_long, selected: _Level.persistent),
      locale: const Locale('ru'),
      scale: 2,
      size: const Size(320, 568),
    );
    expect(
      find.descendant(
        of: find.byKey(_keyOf(_Level.persistent)),
        matching: find.byIcon(Icons.radio_button_checked),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(_keyOf(_Level.quiet)),
        matching: find.byIcon(Icons.radio_button_unchecked),
      ),
      findsOneWidget,
    );
    final node = tester.getSemantics(find.byKey(_keyOf(_Level.persistent)));
    expect(
      node,
      matchesSemantics(
        label: _long[_Level.persistent],
        isButton: true,
        isInMutuallyExclusiveGroup: true,
        isChecked: true,
        hasCheckedState: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('segments are at least a touch target high', (tester) async {
    await pumpThemed(tester, _segmented(_short));
    expect(
      tester.getSize(find.byType(SegmentedButton<_Level>)).height,
      greaterThanOrEqualTo(PillPalSizes.touchTarget),
    );
  });

  testWidgets('both layouts hold in the whole matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => SingleChildScrollView(
        child: SizedBox(
          width: MediaQuery.sizeOf(context).width,
          child: Column(
            children: [
              _segmented(_short),
              _segmented(_long, selected: _Level.quiet),
            ],
          ),
        ),
      ),
      expectTouchTargets: true,
      expectContrast: true,
    );
  });

  testWidgets('a word wider than its segment forces the list', (tester) async {
    await pumpThemed(
      tester,
      _segmented(const {
        _Level.quiet: 'Тихо',
        _Level.normal: 'Обычно',
        _Level.persistent: 'Настойчиво',
      }),
      locale: const Locale('ru'),
      scale: 2,
      size: const Size(320, 568),
    );
    expect(find.byKey(const Key('segmented-radio-list')), findsOneWidget);
  });

  testWidgets('two lines stay segments, three lines make a list',
      (tester) async {
    Future<void> pumpLabels(String label) => pumpThemed(
          tester,
          SizedBox(
            width: 300,
            child: PillPalSegmented<_Level>(
              options: {_Level.quiet: label, _Level.normal: 'B'},
              selected: _Level.quiet,
              onChanged: (_) {},
            ),
          ),
        );
    await pumpLabels('Aa Aa');
    expect(find.byType(SegmentedButton<_Level>), findsOneWidget);
    await pumpLabels('Aaaaaa Aaaaaa Aaaaaa Aaaaaa Aaaaaa Aaaaaa Aaaaaa');
    expect(find.byKey(const Key('segmented-radio-list')), findsOneWidget);
  });

  testWidgets('rejects an empty option set', (tester) async {
    await pumpThemed(
      tester,
      PillPalSegmented<_Level>(
        options: const {},
        selected: _Level.quiet,
        onChanged: (_) {},
      ),
    );
    expect(tester.takeException(), isA<AssertionError>());
  });
}
