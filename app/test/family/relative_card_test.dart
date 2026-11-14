import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/data/repositories/relatives_repository.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../helpers.dart';
import 'family_fixtures.dart';

// The relative card (docs/adr/0020 §4): the private note saved online only,
// the blocks of each link, «веду сам», and the old link route. Synthetic
// data over the in-memory database and a fake backend.

const String _grace = 'grace-self';

class _Calls {
  final List<String> log = [];
  final List<Map<String, Object?>> bodies = [];
}

Future<Map<String, String>> _notes(TestHarness harness) async => {
      for (final row in await harness.db.select(harness.db.relativeNotes).get())
        row.profileId: row.note,
    };

/// Grace sees me (outgoing viewer) and I see her (incoming viewer).
Future<void> _seedMutual(TestHarness harness) async {
  await seedLink(
    harness,
    id: 'out-1',
    counterpart: 'Grace Relative',
    counterpartProfileId: _grace,
  );
  await seedLink(
    harness,
    id: 'in-1',
    direction: LinkDirection.incoming,
    profileId: _grace,
    counterpart: 'Grace Relative',
    profileName: 'Grace Relative',
  );
}

Future<({_Calls calls, TestHarness harness})> _open(
  WidgetTester tester,
  String route, {
  Future<http.Response> Function(http.Request request)? answer,
  Future<void> Function(TestHarness harness)? seed,
}) async {
  final calls = _Calls();
  final harness = TestHarness(
    handler: (request) async {
      calls.log.add('${request.method} ${request.url.path}');
      if (request.body.isNotEmpty) {
        calls.bodies.add(jsonDecode(request.body) as Map<String, Object?>);
      }
      if (answer != null) {
        return answer(request);
      }
      return http.Response('', 503);
    },
  );
  final container = createContainer(harness);
  await harness.seedSelfProfile();
  await seed?.call(harness);
  await pumpApp(tester, harness: harness, container: container);
  openRoute(container, route);
  await tester.pumpAndSettle();
  calls.log.clear();
  calls.bodies.clear();
  return (calls: calls, harness: harness);
}

Future<http.Response> _notesServer(http.Request request) async {
  if (request.url.path == '/v1/relative-notes/$_grace') {
    if (request.method == 'PUT') {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      return jsonResponse(noteJson(_grace, body['note']! as String));
    }
    if (request.method == 'DELETE') {
      return http.Response('', 204);
    }
  }
  return http.Response('', 503);
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('relative-note-field')), text);
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final button = find.byKey(Key(key));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a mutual relative has one card with both link blocks',
      (tester) async {
    await _open(tester, AppRoutes.relative(_grace), seed: _seedMutual);

    expect(find.text('Grace Relative'), findsOneWidget);
    expect(find.text('ward, observer'), findsOneWidget);
    expect(find.byKey(const Key('relative-note-field')), findsOneWidget);
    // I see her: alerts and disconnect.
    expect(find.byKey(const Key('notify-missed')), findsOneWidget);
    expect(find.byKey(const Key('detail-leave')), findsOneWidget);
    // She sees me: role and disconnect.
    expect(find.byKey(const Key('detail-revoke')), findsOneWidget);
    expect(find.text('Disconnect'), findsNWidgets(2));
  });

  testWidgets('saving a note puts the trimmed text online and caches it',
      (tester) async {
    final run = await _open(
      tester,
      AppRoutes.relative(_grace),
      seed: _seedMutual,
      answer: _notesServer,
    );

    await _type(tester, '  Сын  ');
    await _tap(tester, 'relative-note-save');

    expect(run.calls.log, ['PUT /v1/relative-notes/$_grace']);
    expect(run.calls.bodies.single, {'note': 'Сын'});
    expect(await _notes(run.harness), {_grace: 'Сын'});
    // The stored note reaches the screen through the notes stream.
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('relative-note-done')), findsOneWidget);
    // The card's name now leads with the note.
    expect(find.text('Сын (Grace Relative)'), findsOneWidget);
  });

  testWidgets('offline nothing changes on the device and it says why',
      (tester) async {
    final run = await _open(
      tester,
      AppRoutes.relative(_grace),
      seed: (harness) async {
        await _seedMutual(harness);
        await seedNote(harness, _grace, 'Сын');
      },
      answer: (request) async => throw http.ClientException('offline'),
    );

    await _type(tester, 'Брат');
    await _tap(tester, 'relative-note-save');

    expect(await _notes(run.harness), {_grace: 'Сын'});
    expect(
      find.text('The note can be changed only online'),
      findsOneWidget,
    );
    // The typed text stays for a retry.
    expect(find.text('Брат'), findsOneWidget);
  });

  testWidgets('an invalid note is refused before any request', (tester) async {
    final run = await _open(
      tester,
      AppRoutes.relative(_grace),
      seed: _seedMutual,
      answer: _notesServer,
    );

    await _type(tester, '   ');
    await _tap(tester, 'relative-note-save');

    expect(run.calls.log, isEmpty);
    expect(find.text('1 to 20 characters on one line'), findsOneWidget);
  });

  testWidgets('clearing deletes the note online, then from the cache',
      (tester) async {
    final run = await _open(
      tester,
      AppRoutes.relative(_grace),
      seed: (harness) async {
        await _seedMutual(harness);
        await seedNote(harness, _grace, 'Сын');
      },
      answer: _notesServer,
    );

    expect(find.text('Сын (Grace Relative)'), findsOneWidget);
    await _tap(tester, 'relative-note-clear');

    expect(run.calls.log, ['DELETE /v1/relative-notes/$_grace']);
    expect(await _notes(run.harness), isEmpty);
    await tester.pumpAndSettle();
    expect(find.text('Grace Relative'), findsOneWidget);
    expect(find.byKey(const Key('relative-note-clear')), findsNothing);
  });

  testWidgets('too many notes says so and stores nothing', (tester) async {
    final run = await _open(
      tester,
      AppRoutes.relative(_grace),
      seed: _seedMutual,
      answer: (request) async => errorResponse(409, 'too_many_notes'),
    );

    await _type(tester, 'Сын');
    await _tap(tester, 'relative-note-save');

    expect(await _notes(run.harness), isEmpty);
    expect(find.byKey(const Key('relative-note-error')), findsOneWidget);
    expect(find.textContaining('too many notes'), findsOneWidget);
  });

  testWidgets('my managed profile links to its form and keeps no note',
      (tester) async {
    await _open(
      tester,
      AppRoutes.relative('ward-1'),
      seed: (harness) => seedProfile(
        harness,
        id: 'ward-1',
        kind: 'managed',
        role: 'owner',
        name: 'Pat Ward',
      ),
    );

    expect(find.text('I manage'), findsOneWidget);
    expect(find.byKey(const Key('relative-note-field')), findsNothing);
    await _tap(tester, 'relative-managed-edit');
    expect(find.byKey(const Key('ward-name')), findsOneWidget);
  });

  testWidgets('the old link route opens the card of its relative',
      (tester) async {
    await _open(tester, AppRoutes.link('out-1'), seed: _seedMutual);

    expect(find.byKey(const Key('relative-card')), findsOneWidget);
    expect(find.byKey(const Key('notify-missed')), findsOneWidget);
    expect(find.byKey(const Key('detail-revoke')), findsOneWidget);
  });

  testWidgets('revoking the last link drops the note with it', (tester) async {
    final run = await _open(
      tester,
      AppRoutes.relative(_grace),
      seed: (harness) async {
        await seedLink(
          harness,
          id: 'out-1',
          counterpart: 'Grace Relative',
          counterpartProfileId: _grace,
        );
        await seedNote(harness, _grace, 'Сын');
      },
      answer: (request) async => http.Response('', 204),
    );

    await _tap(tester, 'detail-revoke');
    await tester.tap(find.byKey(const Key('confirm-yes')));
    await tester.pumpAndSettle();

    expect(run.calls.log, contains('DELETE /v1/grants/out-1'));
    expect(await _notes(run.harness), isEmpty);
  });

  testWidgets('the Family tab shows the note from the refresh', (tester) async {
    final run = await _open(
      tester,
      AppRoutes.family,
      answer: (request) async => request.url.path == '/v1/grants'
          ? jsonResponse(
              grantsJson(
                outgoing: [
                  outgoingGrantJson(
                    id: 'out-1',
                    grantee: 'Grace Relative',
                    granteeProfileId: _grace,
                  ),
                ],
                notes: [noteJson(_grace, 'Сын')],
              ),
            )
          : http.Response('', 503),
    );

    expect(await _notes(run.harness), {_grace: 'Сын'});
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('relative-$_grace')),
        matching: find.text('Сын (Grace Relative)'),
      ),
      findsOneWidget,
    );
  });
}
