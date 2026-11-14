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
    final user = await env.syncState.boundUserId();
    expect(
        await repository.saveNoteFor(user, _note('grace-self', 'Сын')), isTrue);
    await repository.saveNoteFor(user, _note('grace-self', 'Брат'));
    expect(await notes(), {'grace-self': 'Брат'});

    expect(await repository.dropNoteFor(user, 'grace-self'), isTrue);
    expect(await notes(), isEmpty);
  });

  test('a note answered to another account is never stored', () async {
    expect(
      await repository.saveNoteFor('another-account', _note('g', 'Сын')),
      isFalse,
    );
    expect(await repository.saveNoteFor(null, _note('g', 'Сын')), isFalse);
    expect(await notes(), isEmpty);

    final user = await env.syncState.boundUserId();
    await repository.saveNoteFor(user, _note('g', 'Сын'));
    expect(await repository.dropNoteFor('another-account', 'g'), isFalse);
    expect(await notes(), {'g': 'Сын'});
  });

  test('links answered to another account are not stored', () async {
    final restored = await repository.replaceLinksFor(
      'another-account',
      GrantList(
        outgoing: [_outgoing('out-1')],
        incoming: const [],
        notes: [_note('grace-self', 'Сын')],
      ),
    );

    expect(restored, isNull);
    expect(await repository.links(), isEmpty);
    expect(await notes(), isEmpty);
  });

  test('a refresh asked before a save keeps the newer note', () async {
    final user = await env.syncState.boundUserId();
    final mark = repository.noteWriteMark;
    // Saved while the older answer was on its way.
    await repository.saveNoteFor(user, _note('grace-self', 'Брат'));

    await repository.replaceLinksFor(
      user,
      GrantList(
        outgoing: [_outgoing('out-1')],
        incoming: const [],
        notes: [_note('grace-self', 'Сын')],
      ),
      notesSince: mark,
    );

    expect(await notes(), {'grace-self': 'Брат'});
  });

  test('a refresh asked before a delete does not bring the note back',
      () async {
    final user = await env.syncState.boundUserId();
    await repository.saveNoteFor(user, _note('grace-self', 'Сын'));
    final mark = repository.noteWriteMark;
    await repository.dropNoteFor(user, 'grace-self');

    await repository.replaceLinksFor(
      user,
      GrantList(
        outgoing: [_outgoing('out-1')],
        incoming: const [],
        notes: [_note('grace-self', 'Сын')],
      ),
      notesSince: mark,
    );

    expect(await notes(), isEmpty);
  });

  test('a refresh asked after the save takes the answer', () async {
    final user = await env.syncState.boundUserId();
    await repository.saveNoteFor(user, _note('grace-self', 'Брат'));
    final mark = repository.noteWriteMark;

    await repository.replaceLinksFor(
      user,
      GrantList(
        outgoing: [_outgoing('out-1')],
        incoming: const [],
        notes: [_note('grace-self', 'Сын')],
      ),
      notesSince: mark,
    );

    expect(await notes(), {'grace-self': 'Сын'});
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
    await repository.saveNoteFor(
      await env.syncState.boundUserId(),
      _note('grace-self', 'Сын'),
    );

    await env.account.signedOut();

    expect(await notes(), isEmpty);
  });

  test('another account signing in wipes the notes', () async {
    await repository.saveNoteFor(
      await env.syncState.boundUserId(),
      _note('grace-self', 'Сын'),
    );

    final erased = await env.account.bind(
      const AccessClaims(userId: 'another-account', region: 'ru'),
    );

    expect(erased, isTrue);
    expect(await notes(), isEmpty);
  });
}
