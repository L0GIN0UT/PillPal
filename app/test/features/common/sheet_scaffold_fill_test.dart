import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/features/common/sheet_scaffold.dart';
import 'package:pillpal/src/localization_delegates.dart';
import 'package:pillpal/src/theme/app_theme.dart';
import 'package:pillpal/src/theme/spacing.dart';

// SheetScaffold.fill: one height (the box it gets, at most 90 % of the
// screen), the body fills what the title and the header leave, and below
// the least content height the whole sheet scrolls. That height grows with
// the text by the scaler's factor, also for a nonlinear scaler (Android 14),
// which would barely grow a large height taken as a font size.

/// A nonlinear scaler like Android 14's: x2 for body text, much less for
/// large sizes.
class _Nonlinear extends TextScaler {
  const _Nonlinear();

  @override
  double scale(double fontSize) =>
      fontSize <= 40 ? fontSize * 2 : 80 + (fontSize - 40) * 0.1;

  @override
  double get textScaleFactor => 2;
}

const double _box = 300;

Future<void> _pump(WidgetTester tester, TextScaler scaler) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPillPalTheme(brightness: Brightness.light, senior: false),
      localizationsDelegates: pillPalLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, app) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: scaler),
        child: app!,
      ),
      home: const Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: _box,
            height: _box,
            child: SheetScaffold.fill(
              title: 'Title',
              header: SizedBox(height: 20),
              body: SizedBox.expand(key: Key('body')),
            ),
          ),
        ),
      ),
    ),
  );
}

ScrollPosition _outer(WidgetTester tester) => tester
    .state<ScrollableState>(
      find
          .descendant(
            of: find.byType(SheetScaffold),
            matching: find.byType(Scrollable),
          )
          .first,
    )
    .position;

void main() {
  testWidgets('the body fills the box; nothing scrolls when it is tall enough',
      (tester) async {
    await _pump(tester, TextScaler.noScaling);

    expect(tester.getSize(find.byType(SheetScaffold)).height, _box);
    expect(_outer(tester).maxScrollExtent, 0);
    final body = tester.getRect(find.byKey(const Key('body')));
    expect(body.bottom, _box - PillPalSpacing.sheet.bottom);
    expect(
      tester
          .widget<Semantics>(
            find
                .ancestor(
                    of: find.text('Title'), matching: find.byType(Semantics))
                .first,
          )
          .properties
          .header,
      isTrue,
    );
  });

  testWidgets('the least height grows by the factor of a nonlinear scaler',
      (tester) async {
    await _pump(tester, const _Nonlinear());

    // 280 x 2 = 560 in a 300 box; `scale(280)` would give 104 and no scroll.
    expect(
      _outer(tester).maxScrollExtent,
      PillPalSizes.sheetMinContentHeight * 2 - _box,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('it takes at most 90 % of the screen', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(360, 800);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPillPalTheme(brightness: Brightness.light, senior: false),
        localizationsDelegates: pillPalLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SheetScaffold.fill(body: SizedBox.expand()),
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byType(SheetScaffold)).height,
      800 * PillPalSizes.sheetMaxHeightFactor,
    );
  });
}
