import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/features/family/family_providers.dart';

import '../helpers.dart';
import 'family_fixtures.dart';

// A note request still on its way when the account changes (docs/adr/0020
// §4): its answer belongs to the account that asked and is never written
// to the next one's data, nor to a signed-out device.

const String _grace = 'grace-self';

/// What happens on the device while the request is in flight.
enum _Meanwhile { signOut, otherAccount }

Future<void> _meanwhile(ProviderContainer container, _Meanwhile what) async {
  final db = container.read(databaseProvider);
  await db.wipeAccountData();
  if (what == _Meanwhile.otherAccount) {
    await container.read(syncStateStoreProvider).bindAccount('user-2', 'ru');
  }
}

/// A harness whose backend lets [what] happen before it answers, then
/// answers with [answer].
Future<({TestHarness harness, ProviderContainer container})> _setUp(
  _Meanwhile what,
  http.Response Function(http.Request request) answer,
) async {
  late ProviderContainer container;
  final harness = TestHarness(
    handler: (request) async {
      await _meanwhile(container, what);
      return answer(request);
    },
  );
  container = createContainer(harness);
  addTearDown(container.dispose);
  await container.read(syncStateStoreProvider).bindAccount('user-1', 'ru');
  return (harness: harness, container: container);
}

Future<Map<String, String>> _notes(TestHarness harness) async => {
      for (final row in await harness.db.select(harness.db.relativeNotes).get())
        row.profileId: row.note,
    };

void main() {
  for (final what in _Meanwhile.values) {
    testWidgets('a note saved while the account changes is dropped ($what)',
        (tester) async {
      final run = await _setUp(
        what,
        (request) => jsonResponse(noteJson(_grace, 'Сын')),
      );

      await run.container.read(familyActionsProvider).saveNote(_grace, 'Сын');

      expect(await _notes(run.harness), isEmpty);
    });

    testWidgets(
        'a refresh answered after the account changed is dropped '
        '($what)', (tester) async {
      final run = await _setUp(
        what,
        (request) => request.url.path == '/v1/grants'
            ? jsonResponse(
                grantsJson(
                  outgoing: [
                    outgoingGrantJson(id: 'out-1', granteeProfileId: _grace),
                  ],
                  notes: [noteJson(_grace, 'Сын')],
                ),
              )
            : http.Response('', 503),
      );

      await run.container.read(familyActionsProvider).refresh();

      expect(await _notes(run.harness), isEmpty);
      expect(
        await run.harness.db.select(run.harness.db.relativeLinks).get(),
        isEmpty,
      );
    });
  }

  testWidgets('a delete answered to the old account keeps the next note',
      (tester) async {
    late ProviderContainer container;
    late final TestHarness harness;
    harness = TestHarness(
      handler: (request) async {
        // Another account signs in and its refresh stores its own note.
        await _meanwhile(container, _Meanwhile.otherAccount);
        await seedNote(harness, _grace, 'Мама');
        return http.Response('', 204);
      },
    );
    container = createContainer(harness);
    addTearDown(container.dispose);
    await container.read(syncStateStoreProvider).bindAccount('user-1', 'ru');
    await seedNote(harness, _grace, 'Сын');

    await container.read(familyActionsProvider).clearNote(_grace);

    expect(await _notes(harness), {_grace: 'Мама'});
  });

  testWidgets('a delete while signing out leaves nothing', (tester) async {
    final run = await _setUp(
      _Meanwhile.signOut,
      (request) => http.Response('', 204),
    );
    await seedNote(run.harness, _grace, 'Сын');

    await run.container.read(familyActionsProvider).clearNote(_grace);

    expect(await _notes(run.harness), isEmpty);
  });
}
