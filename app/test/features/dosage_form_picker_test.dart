import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/routing/routes.dart';
import 'package:pillpal/src/settings/app_settings.dart';
import 'package:pillpal/src/theme/sizes.dart';

import '../data/catalog_fixtures.dart';
import '../helpers.dart';
import 'catalog_ui_env.dart';

// The «Форма» field is chosen in a picker (owner request): a standard form
// is stored as its code and shown by its localized name; «Other» stores
// free text; catalog and older free text stay exactly as they are.

Future<void> _tapKey(WidgetTester tester, Key key) async {
  await tester.ensureVisible(find.byKey(key));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(key));
  await tester.pumpAndSettle();
}

Future<void> _openPicker(WidgetTester tester) =>
    _tapKey(tester, const Key('med-form'));

String _shown(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('med-form-text'))).data!;

bool _marked(WidgetTester tester, String code) => tester
    .widget<ListTile>(
      find.descendant(
        of: find.byKey(ValueKey('dosage-form-$code')),
        matching: find.byType(ListTile),
      ),
    )
    .selected;

Future<String?> _storedForm(TestHarness harness) async =>
    (await harness.db.select(harness.db.medications).get()).single.form;

Future<(TestHarness, String, ProviderContainer)> _editExisting(
  WidgetTester tester, {
  required String? form,
  Locale locale = const Locale('en'),
}) async {
  final harness = TestHarness();
  final container = createContainer(harness);
  await harness.seedSelfProfile();
  final id = await harness.seedMedication(container, form: form);
  await pumpApp(
    tester,
    harness: harness,
    container: container,
    locale: locale,
  );
  openRoute(container, AppRoutes.medication(id));
  await tester.pumpAndSettle();
  return (harness, id, container);
}

void main() {
  testWidgets('a standard form is saved as its code, shown by its name',
      (tester) async {
    final harness = TestHarness();
    await harness.seedSelfProfile();
    await pumpApp(tester, harness: harness);
    await tester.tap(find.byKey(const Key('today-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('med-name')), 'Med F');

    expect(_shown(tester), isEmpty);
    expect(find.text('Choose a form'), findsOneWidget);
    await _openPicker(tester);
    expect(find.text('Dosage form'), findsOneWidget);
    expect(_marked(tester, 'drops'), isFalse);
    await _tapKey(tester, const ValueKey('dosage-form-drops'));

    expect(find.text('Dosage form'), findsNothing);
    expect(_shown(tester), 'Drops');
    await _tapKey(tester, const Key('med-save'));
    expect(await _storedForm(harness), 'drops');
  });

  testWidgets('«Other» saves the typed form', (tester) async {
    final (harness, _, _) = await _editExisting(tester, form: null);

    await _openPicker(tester);
    expect(find.byKey(const Key('dosage-form-other-text')), findsNothing);
    await _tapKey(tester, const Key('dosage-form-other'));
    final done = find.byKey(const Key('dosage-form-other-done'));
    expect(tester.widget<FilledButton>(done).onPressed, isNull);
    await tester.enterText(
      find.byKey(const Key('dosage-form-other-text')),
      '  Implant  ',
    );
    await tester.pump();
    await _tapKey(tester, const Key('dosage-form-other-done'));

    expect(_shown(tester), 'Implant');
    await _tapKey(tester, const Key('med-save'));
    expect(await _storedForm(harness), 'Implant');
  });

  testWidgets('a code reads in Russian; the card draws its glyph',
      (tester) async {
    final (_, id, container) = await _editExisting(
      tester,
      form: 'drops',
      locale: const Locale('ru'),
    );

    expect(_shown(tester), 'Капли');
    await _openPicker(tester);
    expect(_marked(tester, 'drops'), isTrue);
    expect(find.text('Форма выпуска'), findsOneWidget);
    await _tapKey(tester, const Key('dosage-form-close'));

    goRoute(container, AppRoutes.medications);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(ValueKey('medication-$id')),
        matching: find.byIcon(Icons.medication_liquid_outlined),
      ),
      findsOneWidget,
    );
  });

  testWidgets('older free text is shown and kept unchanged', (tester) async {
    const legacy = 'ТАБЛЕТКИ, ПОКРЫТЫЕ ПЛЕНОЧНОЙ ОБОЛОЧКОЙ';
    final (harness, _, _) = await _editExisting(tester, form: legacy);

    expect(_shown(tester), legacy);
    await _openPicker(tester);
    expect(_marked(tester, 'tablet'), isTrue);
    expect(find.byKey(const Key('dosage-form-other-text')), findsNothing);
    // The marked row is what the text already says: it stays as it is.
    await _tapKey(tester, const ValueKey('dosage-form-tablet'));

    expect(find.text('Dosage form'), findsNothing);
    expect(_shown(tester), legacy);
    await _tapKey(tester, const Key('med-save'));
    expect(await _storedForm(harness), legacy);
  });

  testWidgets('text of no standard form opens «Other» with it', (tester) async {
    await _editExisting(tester, form: 'Implant');

    expect(_shown(tester), 'Implant');
    await _openPicker(tester);
    for (final code in ['tablet', 'capsule', 'patch']) {
      expect(_marked(tester, code), isFalse);
    }
    final field = find.byKey(const Key('dosage-form-other-text'));
    expect(tester.widget<TextField>(field).controller!.text, 'Implant');
  });

  testWidgets('the form can be cleared', (tester) async {
    final (harness, _, _) = await _editExisting(tester, form: 'tablet');

    expect(_shown(tester), 'Tablets');
    expect(find.text('Remove dosage form'), findsOneWidget);
    await _tapKey(tester, const Key('med-form-clear'));

    expect(_shown(tester), isEmpty);
    expect(find.byKey(const Key('med-form-clear')), findsNothing);
    await _tapKey(tester, const Key('med-save'));
    expect(await _storedForm(harness), isNull);
  });

  testWidgets('a catalog form is kept as it is and marks its group',
      (tester) async {
    final env = CatalogUiEnv()..results = [searchResultJson(id: productA)];
    await env.pump(tester);
    await env.openNewForm(tester);
    await env.searchAndPick(tester, 'synthetic', productA);

    expect(_shown(tester), 'tablets');
    await _openPicker(tester);
    expect(_marked(tester, 'tablet'), isTrue);
    expect(_marked(tester, 'capsule'), isFalse);
    await _tapKey(tester, const ValueKey('dosage-form-capsule'));

    expect(_shown(tester), 'Capsules');
    await env.save(tester);
    expect(await _storedForm(env.harness), 'capsule');
  });

  testWidgets('the field and the picker fit in senior mode, dark, Russian',
      (tester) async {
    const long = 'ПОРОШОК ДЛЯ ПРИГОТОВЛЕНИЯ РАСТВОРА ДЛЯ ПРИЕМА ВНУТРЬ, '
        'ПОКРЫТЫЙ ОЧЕНЬ ДЛИННЫМ ОПИСАНИЕМ ФОРМЫ';
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    final id = await harness.seedMedication(container, form: long);
    await pumpApp(
      tester,
      harness: harness,
      container: container,
      locale: const Locale('ru'),
      configure: (scope) {
        scope.read(settingsProvider.notifier)
          ..setSeniorMode(enabled: true)
          ..setThemeMode(ThemeMode.dark);
      },
    );
    openRoute(container, AppRoutes.medication(id));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(_shown(tester), long);
    expect(
      tester.getSize(find.byKey(const Key('med-form'))).height,
      greaterThanOrEqualTo(PillPalSizes.seniorButtonHeight),
    );

    await _openPicker(tester);
    expect(tester.takeException(), isNull);
    expect(_marked(tester, 'powder'), isTrue);
    for (final code in ['tablet', 'patch']) {
      final row = find.byKey(ValueKey('dosage-form-$code'));
      await tester.ensureVisible(row);
      expect(
        tester.getSize(row).height,
        greaterThanOrEqualTo(PillPalSizes.seniorButtonHeight),
      );
    }
    await _tapKey(tester, const Key('dosage-form-other'));
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const Key('dosage-form-other-done')),
      findsOneWidget,
    );
  });

  testWidgets('a second tap does not open a second picker', (tester) async {
    await _editExisting(tester, form: null);

    await tester.tap(find.byKey(const Key('med-form')));
    await tester.tap(find.byKey(const Key('med-form')), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.byType(BottomSheet), findsOneWidget);
  });

  testWidgets('a chosen code of the catalog group needs no offer',
      (tester) async {
    final env = CatalogUiEnv()..results = [searchResultJson(id: productA)];
    await env.pump(tester);
    await env.openNewForm(tester);
    await _openPicker(tester);
    await _tapKey(tester, const ValueKey('dosage-form-tablet'));

    await env.searchAndPick(tester, 'synthetic', productA);

    expect(find.byKey(const ValueKey('catalog-offer-form')), findsNothing);
    expect(_shown(tester), 'Tablets');
    await env.save(tester);
    expect(await _storedForm(env.harness), 'tablet');
  });
}
