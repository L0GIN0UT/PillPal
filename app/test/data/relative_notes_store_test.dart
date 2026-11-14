import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/api/relatives_dto.dart';
import 'package:pillpal/src/data/auth/access_claims.dart';
import 'package:pillpal/src/data/repositories/relatives_repository.dart';

import 'test_env.dart';

// The local cache of private relative notes (docs/adr/0020 §4): replaced
// with every refresh of the links, written only after the server accepted a
// change, gone with the relationship and with the account. Synthetic data.

final DateTime _at = DateTime.utc(2026, 10, 12);

OutgoingGrant _outgoing(String id, {String? grantee = 'grace-self'}) =>
    OutgoingGrant(
      id: id,
      profileId: 'my-self',
      profileDisplayName: 'Me',
      profileKind: 'self',
      role: 'viewer',
      granteeDisplayName: 'Grace',
      granteeProfileId: grantee,
      active: true,
      disclosureVersion: 1,
      createdAt: _at,
    );

IncomingGrant _incoming(String id, String profileId) => IncomingGrant(
      id: id,
      profileId: profileId,
      profileDisplayName: 'Grace',
      profileKind: 'self',
      role: 'viewer',
      ownerDisplayName: 'Grace',
      notifyMissed: true,
      createdAt: _at,
    );

RelativeNote _note(String profileId, String note) =>
    RelativeNote(profileId: profileId, note: note, updatedAt: _at);

void main() {
  late TestEnv env;
  late RelativesRepository repository;

  setUp(() async {
    env = await TestEnv.create();
    repository = RelativesRepository(env.db, env.syncState);
  });

  tearDown(() => env.dispose());

  Future<Map<String, String>> notes() => repository.watchNotes().first;

  test('a refresh stores the counterpart profiles and the notes', () async {
    await repository.replaceLinks(
      GrantList(
        outgoing: [_outgoing('out-1')],
        incoming: [_incoming('in-1', 'robin-self')],
        notes: [_note('grace-self', 'Сын')],
      ),
    );

    final links = {for (final link in await repository.links()) link.id: link};
    expect(links['out-1']!.counterpartProfileId, 'grace-self');
    // An incoming link's own profile stands for its person.
    expect(links['in-1']!.counterpartProfileId, 'robin-self');
    expect(await notes(), {'grace-self': 'Сын'});
  });

  test('the next refresh replaces the notes wholesale', () async {
    await repository.replaceLinks(
      GrantList(
        outgoing: [_outgoing('out-1')],
        incoming: const [],
        notes: [_note('grace-self', 'Сын')],
      ),
    );
    await repository.replaceLinks(
      GrantList(outgoing: [_outgoing('out-1')], incoming: const []),
    );

    expect(await notes(), isEmpty);
  });

  test('a saved note replaces the stored one; a dropped one goes', () async {
    await repository.saveNote(_note('grace-self', 'Сын'));
    await repository.saveNote(_note('grace-self', 'Брат'));
    expect(await notes(), {'grace-self': 'Брат'});

    await repository.dropNote('grace-self');
    expect(await notes(), isEmpty);
  });

  test('forgetting the last link drops the note, another link keeps it',
      () async {
    await repository.replaceLinks(
      GrantList(
        outgoing: [_outgoing('out-1')],
        incoming: [_incoming('in-1', 'grace-self')],
        notes: [_note('grace-self', 'Сын')],
      ),
    );

    await repository.forget('in-1');
    expect(await notes(), {'grace-self': 'Сын'}, reason: 'still related');

    await repository.forget('out-1');
    expect(await notes(), isEmpty);
  });

  test('signing out wipes the notes', () async {
    await repository.saveNote(_note('grace-self', 'Сын'));

    await env.account.signedOut();

    expect(await notes(), isEmpty);
  });

  test('another account signing in wipes the notes', () async {
    await repository.saveNote(_note('grace-self', 'Сын'));

    final erased = await env.account.bind(
      const AccessClaims(userId: 'another-account', region: 'ru'),
    );

    expect(erased, isTrue);
    expect(await notes(), isEmpty);
  });
}
