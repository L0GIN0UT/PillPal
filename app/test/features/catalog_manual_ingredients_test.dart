import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/data/catalog/manual_ingredient.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../data/catalog_fixtures.dart';
import '../helpers.dart';
import 'catalog_ui_env.dart';

// The private manual composition (ADR 0015 §4): up to ten lines, picked from
// the catalog or typed; an untouched editor keeps what is stored.

Future<List<Map<String, Object?>>> _stored(CatalogUiEnv env) async {
  final rows = await env.harness.db.select(env.harness.db.medications).get();
  final text = rows.single.manualIngredients;
  if (text == null) {
    return const [];
  }
  return (jsonDecode(text) as List<Object?>).cast<Map<String, Object?>>();
}

void main() {
  testWidgets('typed lines are saved; free text carries no substance id',
      (tester) async {
    final env = CatalogUiEnv();
    await env.pump(tester);
    await env.openNewForm(tester);
    await tester.enterText(find.byKey(const Key('med-name')), 'Med');

    await tester.ensureVisible(find.byKey(const Key('manual-ing-add')));
    await tester.tap(find.byKey(const Key('manual-ing-add')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('manual-ing-name-0')),
      'Моя соль',
    );
    await tester.enterText(
      find.byKey(const Key('manual-ing-strength-0')),
      '5 мг',
    );
    await env.save(tester);

    expect(await _stored(env), [
      {'substance_id': null, 'name': 'Моя соль', 'strength_text': '5 мг'},
    ]);
  });

  testWidgets('a substance picked from the catalog keeps its id',
      (tester) async {
    final env = CatalogUiEnv()
      ..substanceResults = [
        searchResultJson(
          id: substanceX,
          kind: 'substance',
          name: 'Picked substance',
        ),
      ];
    await env.pump(tester);
    await env.openNewForm(tester);
    await tester.enterText(find.byKey(const Key('med-name')), 'Med');

    await tester.ensureVisible(find.byKey(const Key('manual-ing-pick')));
    await tester.tap(find.byKey(const Key('manual-ing-pick')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('catalog-search-text')),
      'picked',
    );
    await tester.tap(find.byKey(const Key('catalog-search-go')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('catalog-result-$substanceX')));
    await tester.pumpAndSettle();
    await env.save(tester);

    final lines = await _stored(env);
    expect(lines.single['substance_id'], substanceX);
    expect(lines.single['name'], 'Picked substance');
    final request = env.traffic.requests.single;
    expect(jsonDecode(request.body), containsPair('kind', 'substance'));
  });

  testWidgets('editing the name of a picked line drops its substance id',
      (tester) async {
    final env = CatalogUiEnv();
    final container = await env.pump(tester);
    final id = await container.read(medicationsRepositoryProvider).create(
          profileId: selfProfileId,
          draft: const MedicationDraft(
            name: 'Med',
            manualIngredients: [
              ManualIngredient(name: 'Picked', substanceId: substanceX),
            ],
          ),
        );
    openRoute(container, AppRoutes.medication(id));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('manual-ing-name-0')));
    await tester.enterText(
      find.byKey(const Key('manual-ing-name-0')),
      'Picked, edited',
    );
    await env.save(tester);

    final lines = await _stored(env);
    expect(lines.single['name'], 'Picked, edited');
    expect(lines.single['substance_id'], isNull);
  });

  testWidgets('an untouched editor keeps the stored composition',
      (tester) async {
    final env = CatalogUiEnv();
    final container = await env.pump(tester);
    final id = await container.read(medicationsRepositoryProvider).create(
          profileId: selfProfileId,
          draft: const MedicationDraft(
            name: 'Med',
            manualIngredients: [
              ManualIngredient(name: 'Picked', substanceId: substanceX),
            ],
          ),
        );
    openRoute(container, AppRoutes.medication(id));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('med-name')), 'Renamed');
    await env.save(tester);

    final lines = await _stored(env);
    expect(lines.single['substance_id'], substanceX);
  });

  testWidgets('removing the last line clears the composition', (tester) async {
    final env = CatalogUiEnv();
    final container = await env.pump(tester);
    final id = await container.read(medicationsRepositoryProvider).create(
          profileId: selfProfileId,
          draft: const MedicationDraft(
            name: 'Med',
            manualIngredients: [ManualIngredient(name: 'Salt')],
          ),
        );
    openRoute(container, AppRoutes.medication(id));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('manual-ing-remove-0')));
    await tester.tap(find.byKey(const Key('manual-ing-remove-0')));
    await tester.pumpAndSettle();
    await env.save(tester);

    expect(await _stored(env), isEmpty);
  });

  testWidgets('at most ten lines can be added', (tester) async {
    final env = CatalogUiEnv();
    await env.pump(tester);
    await env.openNewForm(tester);

    for (var i = 0; i < 10; i++) {
      await tester.ensureVisible(find.byKey(const Key('manual-ing-add')));
      await tester.tap(find.byKey(const Key('manual-ing-add')));
      await tester.pump();
    }

    expect(find.byKey(const Key('manual-ing-add')), findsNothing);
    expect(find.byKey(const Key('manual-ing-max')), findsOneWidget);
  });
}
