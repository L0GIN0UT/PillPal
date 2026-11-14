import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/repositories/profile_access.dart';
import 'package:pillpal/src/data/repositories/relatives_repository.dart';
import 'package:pillpal/src/features/family/relatives_list.dart';

// The one list «Близкие» (docs/adr/0020 §4) built from the stored links,
// profiles and notes: plain unit tests, synthetic data.

RelativeLinkRow _link(
  String id, {
  required String direction,
  required String profileId,
  String? counterpartProfileId,
  String role = 'viewer',
  String? counterpart,
  String profileName = 'Owner Profile',
  String profileKind = 'self',
  bool active = true,
  int createdAt = 1,
}) =>
    RelativeLinkRow(
      id: id,
      direction: direction,
      profileId: profileId,
      role: role,
      counterpartName: counterpart,
      active: active,
      notifyMissed: true,
      createdAt: createdAt,
      profileName: profileName,
      profileKind: profileKind,
      counterpartProfileId: counterpartProfileId,
    );

RelativeLinkRow _incoming(
  String id,
  String profileId, {
  String role = 'viewer',
  String profileName = 'Grace',
  String profileKind = 'self',
  String? owner = 'Grace Owner',
}) =>
    _link(
      id,
      direction: LinkDirection.incoming,
      profileId: profileId,
      counterpartProfileId: profileId,
      role: role,
      counterpart: owner,
      profileName: profileName,
      profileKind: profileKind,
    );

RelativeLinkRow _outgoing(
  String id, {
  String? grantee = 'grace-self',
  String role = 'viewer',
  String? name = 'Grace G.',
  String profileId = 'my-self',
  String profileName = 'Me',
  String profileKind = 'self',
  bool active = true,
}) =>
    _link(
      id,
      direction: LinkDirection.outgoing,
      profileId: profileId,
      counterpartProfileId: grantee,
      role: role,
      counterpart: name,
      profileName: profileName,
      profileKind: profileKind,
      active: active,
    );

ProfileAccess _managed(String id, String name, {String role = 'owner'}) =>
    ProfileAccess(
      profile: ProfileRow(
        id: id,
        kind: 'managed',
        displayName: name,
        timezone: 'Europe/Berlin',
        clientUpdatedAt: 1,
        updatedByDevice: 'device',
        missedAlertMinutes: 30,
        missedAlertsEnabled: true,
      ),
      role: role,
    );

void main() {
  test('a person related both ways is one row with both roles', () {
    final rows = buildRelatives(
      links: [_incoming('in-1', 'grace-self'), _outgoing('out-1')],
      profiles: const [],
    );

    expect(rows, hasLength(1));
    final row = rows.single;
    expect(row.key, 'grace-self');
    expect(row.subjectProfileId, 'grace-self');
    expect(row.name, 'Grace');
    expect(row.roles, const [
      RelativeRole(RelativeRoleKind.ward),
      RelativeRole(RelativeRoleKind.observer),
    ]);
    expect(row.dayProfileId, 'grace-self');
    expect(row.canHaveNote, isTrue);
  });

  test('roles follow the direction and the role of each link', () {
    final rows = buildRelatives(
      links: [
        _incoming('in-1', 'ward-editor', role: 'editor'),
        _outgoing('out-1', grantee: 'helper', role: 'editor'),
        _outgoing(
          'out-2',
          grantee: 'guardian',
          role: 'guardian',
          profileId: 'my-pat',
          profileName: 'Pat',
          profileKind: 'managed',
        ),
      ],
      profiles: const [],
    );

    expect(
      {for (final row in rows) row.key: row.roles.single},
      {
        'ward-editor': const RelativeRole(RelativeRoleKind.wardEditor),
        'helper': const RelativeRole(RelativeRoleKind.helper),
        'guardian': const RelativeRole(
          RelativeRoleKind.guardian,
          profileName: 'Pat',
        ),
      },
    );
    // Only who I see has a day to open.
    expect(rows.first.dayProfileId, 'ward-editor');
    expect(rows[1].dayProfileId, isNull);
  });

  test('my managed profile is «веду сам» and keeps no note', () {
    final rows = buildRelatives(
      links: const [],
      profiles: [_managed('pat', 'Pat')],
      notes: const {'pat': 'Ignored'},
    );

    final row = rows.single;
    expect(row.roles, const [RelativeRole(RelativeRoleKind.managedByMe)]);
    expect(row.name, 'Pat');
    expect(row.dayProfileId, 'pat');
    expect(row.canHaveNote, isFalse);
    expect(row.note, isNull);
  });

  test('a co-guarded profile merges the link and the profile', () {
    final rows = buildRelatives(
      links: [
        _incoming(
          'in-1',
          'sam',
          role: 'guardian',
          profileName: 'Sam',
          profileKind: 'managed',
          owner: 'Robin',
        ),
      ],
      profiles: [_managed('sam', 'Sam', role: 'guardian')],
    );

    final row = rows.single;
    expect(row.roles, const [
      RelativeRole(RelativeRoleKind.coGuardian, ownerName: 'Robin'),
    ]);
    expect(row.access?.id, 'sam');
    expect(row.canHaveNote, isTrue);
  });

  test('an archive without a link still lists as co-guarded and archived', () {
    final archive = ProfileAccess(
      profile: _managed('old', 'Old').profile,
      role: 'guardian',
      archived: true,
    );

    final row = buildRelatives(links: const [], profiles: [archive]).single;

    expect(row.roles, const [RelativeRole(RelativeRoleKind.coGuardian)]);
    expect(row.archived, isTrue);
    expect(row.inactive, isFalse);
  });

  test('a row of paused links only is inactive, one live link is enough', () {
    final paused = buildRelatives(
      links: [_outgoing('out-1', active: false)],
      profiles: const [],
    ).single;
    expect(paused.inactive, isTrue);
    expect(paused.roles.single.active, isFalse);

    final mixed = buildRelatives(
      links: [
        _outgoing('out-1', active: false),
        _outgoing(
          'out-2',
          profileId: 'my-pat',
          profileName: 'Pat',
          profileKind: 'managed',
        ),
      ],
      profiles: const [],
    ).single;
    expect(mixed.inactive, isFalse);
    expect(mixed.outgoing, hasLength(2));
  });

  test('a paused incoming link gives no day and reads inactive', () {
    final paused = _link(
      'in-1',
      direction: LinkDirection.incoming,
      profileId: 'grace-self',
      counterpartProfileId: 'grace-self',
      active: false,
    );

    final row = buildRelatives(links: [paused], profiles: const []).single;

    expect(row.inactive, isTrue);
    expect(row.dayProfileId, isNull);
    expect(row.roles.single,
        const RelativeRole(RelativeRoleKind.ward, active: false));

    // A live link the other way keeps the row active, still without a day.
    final mutual = buildRelatives(
      links: [paused, _outgoing('out-1')],
      profiles: const [],
    ).single;
    expect(mutual.inactive, isFalse);
    expect(mutual.dayProfileId, isNull);
  });

  test('without a grantee profile the link id keys the row, no note', () {
    final row = buildRelatives(
      links: [_outgoing('out-1', grantee: null)],
      profiles: const [],
      notes: const {'out-1': 'Never'},
    ).single;

    expect(row.key, 'out-1');
    expect(row.subjectProfileId, isNull);
    expect(row.canHaveNote, isFalse);
    expect(row.note, isNull);
  });

  test('notes attach by subject profile and format the title', () {
    final row = buildRelatives(
      links: [_outgoing('out-1')],
      profiles: const [],
      notes: const {'grace-self': 'Сын'},
    ).single;

    expect(row.note, 'Сын');
    expect(relativeTitle(name: row.name, note: row.note), 'Сын (Grace G.)');
    expect(relativeTitle(name: 'Grace'), 'Grace');
  });

  test('the name falls back from the profile to the counterpart to empty', () {
    final rows = buildRelatives(
      links: [
        _incoming('in-1', 'a', profileName: ''),
        _outgoing('out-1', grantee: 'b', name: null),
      ],
      profiles: const [],
    );

    expect(rows.first.name, 'Grace Owner');
    expect(rows.last.name, '');
  });

  test('order: managed profiles, people I see, people who see me', () {
    final rows = buildRelatives(
      links: [
        _outgoing('out-1', grantee: 'only-sees-me'),
        _incoming('in-1', 'i-see'),
      ],
      profiles: [_managed('pat', 'Pat')],
    );

    expect([for (final row in rows) row.key], ['pat', 'i-see', 'only-sees-me']);
  });

  test('the debug text carries no name or note', () {
    final row = buildRelatives(
      links: [_outgoing('out-1')],
      profiles: const [],
      notes: const {'grace-self': 'Синтетика'},
    ).single;

    expect(row.toString(), isNot(contains('Grace')));
    expect(row.toString(), isNot(contains('Синтетика')));
  });
}
