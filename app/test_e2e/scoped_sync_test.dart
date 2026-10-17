import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/clock.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';

import 'device.dart';

// End-to-end of the scoped sync (ADR 0006) with two accounts against the
// real backend (CI job "app / e2e"): an owner shares a profile with a
// viewer through an invite, and the viewer's device holds exactly what the
// privacy level allows until the grant is revoked. Skipped without
// PILLPAL_E2E_BASE_URL / PILLPAL_E2E_LOG.

const String _plainDose = 'tablet';

Map<String, Object?> _rule(String time) => {
      'v': 1,
      'kind': 'daily',
      'start_date': '2026-10-01',
      'end_date': null,
      'times': [
        {
          'time': time,
          'dose': {'amount': '1', 'unit': _plainDose},
        },
      ],
    };

Map<String, Object?> _decode(String body) =>
    jsonDecode(body) as Map<String, Object?>;

void main() {
  final baseUrl = Platform.environment['PILLPAL_E2E_BASE_URL'];
  final logPath = Platform.environment['PILLPAL_E2E_LOG'];
  final skip = baseUrl == null || logPath == null
      ? 'PILLPAL_E2E_BASE_URL / PILLPAL_E2E_LOG not set'
      : null;

  test(
    'a viewer holds the privacy projection of a shared profile until revoked',
    () async {
      final owner = Device(Uri.parse(baseUrl!));
      final viewer = Device(Uri.parse(baseUrl));
      addTearDown(owner.close);
      addTearDown(viewer.close);
      final stamp = DateTime.now().microsecondsSinceEpoch;
      await owner.signUp(
        email: 'e2e-owner-$stamp@example.com',
        password: 'e2e-password-1',
        logPath: logPath!,
      );
      await viewer.signUp(
        email: 'e2e-viewer-$stamp@example.com',
        password: 'e2e-password-1',
        logPath: logPath,
      );

      // The owner has one medication per privacy level.
      await owner.sync();
      final self = (await owner.profiles.watchAll().first).single;
      final medications = <String, String>{};
      for (final privacy in ['shared', 'anonymous', 'hidden']) {
        final id = await owner.medications.create(
          profileId: self.id,
          draft: MedicationDraft(
            name: 'Med $privacy',
            notes: 'note $privacy',
            privacy: privacy,
          ),
        );
        medications[privacy] = id;
        await owner.schedules.create(medicationId: id, rule: _rule('08:00'));
      }
      await owner.sync();

      // The invite travels outside the app; the token is the URL fragment.
      final invite = await owner.request(
        'POST',
        '/v1/profiles/${self.id}/invites',
        body: {'id': newUuid(), 'role': 'viewer', 'disclosure_version': 1},
      );
      expect(invite.statusCode, 201);
      final token = Uri.parse(_decode(invite.body)['url']! as String).fragment;
      final accepted = await viewer.request(
        'POST',
        '/v1/invites/accept',
        body: {'token': token},
      );
      expect(accepted.statusCode, 201);

      await viewer.sync();

      final scope = await (viewer.db.select(viewer.db.accessScopes)
            ..where((row) => row.profileId.equals(self.id)))
          .getSingle();
      expect(scope.role, ScopeRole.viewer);
      expect(scope.cursor, greaterThan(0));

      final seen = await (viewer.db.select(viewer.db.medications)
            ..where((row) => row.profileId.equals(self.id)))
          .get();
      final byId = {for (final row in seen) row.id: row};
      expect(
        byId.keys,
        unorderedEquals([medications['shared'], medications['anonymous']]),
        reason: 'a hidden medication never reaches a relative',
      );
      final shared = byId[medications['shared']]!;
      expect(shared.name, 'Med shared');
      expect(shared.redacted, isFalse);
      final anonymous = byId[medications['anonymous']]!;
      expect(anonymous.redacted, isTrue);
      expect(anonymous.name, isNull);
      expect(anonymous.notes, isNull);

      final schedules = await viewer.db.select(viewer.db.schedules).get();
      final anonymousSchedule = schedules
          .where((row) => row.medicationId == medications['anonymous'])
          .single;
      expect(anonymousSchedule.redacted, isTrue);
      expect(anonymousSchedule.rule, isNot(contains(_plainDose)));
      expect(
        schedules.where((row) => row.medicationId == medications['hidden']),
        isEmpty,
      );
      expect(
        (await viewer.db.select(viewer.db.outbox).get()).where(
          (entry) => entry.profileId == self.id,
        ),
        isEmpty,
        reason: 'a viewer never queues writes into a foreign scope',
      );

      // Revocation: the next pull evicts the whole scope.
      final grants = _decode((await owner.request('GET', '/v1/grants')).body);
      final grantId =
          ((grants['outgoing']! as List<Object?>).single!
              as Map<String, Object?>)['id']!;
      final revoked = await owner.request('DELETE', '/v1/grants/$grantId');
      expect(revoked.statusCode, 204);

      await viewer.sync();

      expect(
        await (viewer.db.select(viewer.db.accessScopes)
              ..where((row) => row.profileId.equals(self.id)))
            .get(),
        isEmpty,
      );
      expect(
        await (viewer.db.select(viewer.db.profiles)
              ..where((row) => row.id.equals(self.id)))
            .get(),
        isEmpty,
      );
      expect(
        await (viewer.db.select(viewer.db.medications)
              ..where((row) => row.profileId.equals(self.id)))
            .get(),
        isEmpty,
      );
      expect(await viewer.db.select(viewer.db.schedules).get(), isEmpty);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
