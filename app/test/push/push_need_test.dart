import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/api/api_exception.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/repositories/relatives_repository.dart';
import 'package:pillpal/src/push/push_need.dart';

import '../data/test_env.dart' show FakeClock;

const String _own = 'own-profile';
const String _ward = 'ward-profile';
const String _other = 'other-profile';

void main() {
  late AppDatabase db;
  late FakeClock clock;
  late Map<String, bool> openInvites;
  late List<String> asked;
  Object? inviteError;

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    db = AppDatabase(NativeDatabase.memory());
    clock = FakeClock(DateTime.utc(2026, 10, 16, 9));
    openInvites = {};
    asked = [];
    inviteError = null;
  });
  tearDown(() => db.close());

  LocalPushNeed need() => LocalPushNeed(
        db: db,
        clock: clock.call,
        hasOpenInvite: (profileId) async {
          asked.add(profileId);
          final error = inviteError;
          if (error != null) {
            throw error;
          }
          return openInvites[profileId] ?? false;
        },
      );

  Future<void> scope(
    String profileId, {
    String role = ScopeRole.owner,
    String kind = 'self',
    bool archived = false,
  }) {
    return db.into(db.accessScopes).insert(
          AccessScopesCompanion.insert(
            profileId: profileId,
            role: role,
            kind: kind,
            archived: Value(archived),
          ),
        );
  }

  Future<void> link(
    String id, {
    String direction = LinkDirection.incoming,
    String profileId = _other,
    String role = 'viewer',
    bool active = true,
    bool notifyMissed = true,
  }) {
    return db.into(db.relativeLinks).insert(
          RelativeLinksCompanion.insert(
            id: id,
            direction: direction,
            profileId: profileId,
            role: role,
            active: Value(active),
            notifyMissed: Value(notifyMissed),
            createdAt: 1,
          ),
        );
  }

  test('an account with only its own profile does not need alerts', () async {
    await scope(_own);
    expect(await need().isNeeded(), isFalse);
    expect(asked, [_own], reason: 'only the invite check goes to the server');
  });

  test('an incoming grant is a need, without asking the server', () async {
    await scope(_own);
    await scope(_other, role: ScopeRole.viewer);
    await link('g1');
    expect(await need().isNeeded(), isTrue);
    expect(asked, isEmpty);
  });

  test('an incoming grant whose holder turned the alerts off is not', () async {
    await scope(_own);
    await scope(_other, role: ScopeRole.editor);
    await link('g1', role: 'editor', notifyMissed: false);
    expect(await need().isNeeded(), isFalse);
  });

  test('a guardian role is a need even before the link list arrived', () async {
    await scope(_own);
    await scope(_ward, role: ScopeRole.guardian, kind: 'managed');
    expect(await need().isNeeded(), isTrue);
  });

  test('a grant accepted a moment ago counts before its scope is pulled',
      () async {
    await scope(_own);
    await link('g1');
    expect(await need().isNeeded(), isTrue);
  });

  test('an archived profile never counts', () async {
    await scope(_own);
    await scope(
      _ward,
      role: ScopeRole.guardian,
      kind: 'managed',
      archived: true,
    );
    await scope(_other, role: ScopeRole.viewer, archived: true);
    expect(await need().isNeeded(), isFalse);
  });

  test('a managed profile of mine with a co-guardian is a need', () async {
    await scope(_own);
    await scope(_ward, kind: 'managed');
    await link(
      'g2',
      direction: LinkDirection.outgoing,
      profileId: _ward,
      role: 'guardian',
    );
    expect(await need().isNeeded(), isTrue);
    expect(asked, isEmpty);
  });

  test('a managed profile without co-guardians is not', () async {
    await scope(_own);
    await scope(_ward, kind: 'managed');
    await link(
      'g2',
      direction: LinkDirection.outgoing,
      profileId: _ward,
      role: 'viewer',
    );
    await link(
      'g3',
      direction: LinkDirection.outgoing,
      profileId: _ward,
      role: 'guardian',
      active: false,
    );
    expect(await need().isNeeded(), isFalse);
  });

  test('an outgoing viewer of my own profile is not a need by itself',
      () async {
    await scope(_own);
    await link(
      'g4',
      direction: LinkDirection.outgoing,
      profileId: _own,
      role: 'viewer',
    );
    expect(await need().isNeeded(), isFalse);
  });

  group('open invites', () {
    test('an open invite is a need', () async {
      await scope(_own);
      openInvites[_own] = true;
      expect(await need().isNeeded(), isTrue);
    });

    test('the answer is reused until it expires or invites change', () async {
      await scope(_own);
      final rule = need();
      expect(await rule.isNeeded(), isFalse);
      openInvites[_own] = true;
      expect(await rule.isNeeded(), isFalse);
      expect(asked, hasLength(1));
      rule.invitesChanged();
      expect(await rule.isNeeded(), isTrue);
      clock.advance(const Duration(hours: 1));
      openInvites[_own] = false;
      expect(await rule.isNeeded(), isFalse);
      expect(asked, hasLength(3));
    });

    test('offline, the answer is unknown, and is asked again', () async {
      await scope(_own);
      inviteError = const ApiException(ApiException.networkError, 0);
      final rule = need();
      expect(await rule.isNeeded(), isNull);
      inviteError = null;
      openInvites[_own] = true;
      expect(await rule.isNeeded(), isTrue);
    });

    test('before the first pull there is nothing to ask about', () async {
      expect(await need().isNeeded(), isFalse);
      expect(asked, isEmpty);
    });

    test('an owned managed profile is asked about too', () async {
      await scope(_own);
      await scope(_ward, kind: 'managed');
      openInvites[_ward] = true;
      expect(await need().isNeeded(), isTrue);
      expect(asked, contains(_ward));
    });
  });
}
