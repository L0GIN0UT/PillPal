import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/api/api_exception.dart';
import 'package:pillpal/src/data/repositories/dose_events_repository.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';

import 'device.dart';
import 'relatives_support.dart';

// End-to-end of milestone 3 (relatives) with real accounts against the real
// backend (CI job "app / e2e"): the privacy matrix, what each role may
// write, revocation, and the delete -> restore round trip of the owner.
// Skipped without PILLPAL_E2E_BASE_URL / PILLPAL_E2E_LOG.

void main() {
  final baseUrl = Platform.environment['PILLPAL_E2E_BASE_URL'];
  final logPath = Platform.environment['PILLPAL_E2E_LOG'];
  final skip = baseUrl == null || logPath == null
      ? 'PILLPAL_E2E_BASE_URL / PILLPAL_E2E_LOG not set'
      : null;

  test(
    'roles see the privacy projection, write what they may, lose it on revoke',
    () async {
      final url = Uri.parse(baseUrl!);
      final owner = await signedUpDevice(url, logPath!, 'owner');
      final viewer = await signedUpDevice(url, logPath, 'viewer');
      final editor = await signedUpDevice(url, logPath, 'editor');
      final guardian = await signedUpDevice(url, logPath, 'guardian');

      // The owner: one medication per privacy level, and a managed profile.
      final self = (await owner.profiles.watchAll().first).single.id;
      final ward = await owner.profiles.create(
        displayName: 'Grandma',
        timezone: 'UTC',
      );
      final meds = {
        for (final privacy in privacyLevels)
          privacy: await addMedication(owner, self, privacy),
      };
      final wardMed = await addMedication(owner, ward, 'shared');
      await owner.sync();

      await link(owner, self, 'viewer', viewer);
      await link(owner, self, 'editor', editor);
      await link(owner, ward, 'guardian', guardian);
      for (final relative in [viewer, editor, guardian]) {
        await relative.sync();
      }
      expect(await roleOf(viewer, self), 'viewer');
      expect(await roleOf(editor, self), 'editor');
      expect(await roleOf(guardian, ward), 'guardian');

      // The matrix: viewers and editors get the same projection.
      for (final relative in [viewer, editor]) {
        await _expectProjection(relative, self, meds);
        expect(await roleOf(relative, ward), isNull, reason: 'not shared');
      }
      final wardSeen = await medicationsOf(guardian, ward);
      expect(wardSeen[wardMed.id]!.name, wardMed.name);
      expect(wardSeen[wardMed.id]!.redacted, isFalse);
      expect(await roleOf(guardian, self), isNull, reason: 'not shared');

      await _viewerCannotWrite(viewer, owner, self, meds['shared']!);
      await _editorWrites(editor, owner, self, meds);
      await _guardianMarks(guardian, owner, ward, wardMed);

      await _revokeAll(owner);
      for (final relative in [viewer, editor]) {
        await relative.sync();
        await expectEvicted(
          relative,
          self,
          meds.values.map((med) => med.id),
        );
      }
      await guardian.sync();
      await expectEvicted(guardian, ward, [wardMed.id]);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'an owner who deletes the account and restores it gives access back',
    () async {
      final url = Uri.parse(baseUrl!);
      final owner = await signedUpDevice(url, logPath!, 'del-owner');
      final viewer = await signedUpDevice(url, logPath, 'del-viewer');
      final guardian = await signedUpDevice(url, logPath, 'del-guardian');
      final self = (await owner.profiles.watchAll().first).single.id;
      final ward = await owner.profiles.create(
        displayName: 'Grandma',
        timezone: 'UTC',
      );
      final med = await addMedication(owner, self, 'shared');
      final wardMed = await addMedication(owner, ward, 'shared');
      await owner.sync();
      await link(owner, self, 'viewer', viewer);
      await link(owner, ward, 'guardian', guardian);
      await viewer.sync();
      await guardian.sync();
      expect(await medicationsOf(viewer, self), contains(med.id));
      expect(await medicationsOf(guardian, ward), contains(wardMed.id));

      // Deleting the account: the request is enough for grantees to lose
      // the scope (the data is only kept, blocked, to allow a restore); a
      // guardian keeps the managed profile as a read-only archive.
      final deleted = await owner.request(
        'DELETE',
        '/v1/me',
        body: {'password': e2ePassword},
      );
      expect(deleted.statusCode, 204);
      await viewer.sync();
      await guardian.sync();
      await expectEvicted(viewer, self, [med.id]);
      expect(await _isArchived(guardian, ward), isTrue);
      expect(await medicationsOf(guardian, ward), contains(wardMed.id));

      // Signing in answers with a restore ticket; the code is mailed.
      final known = (await verificationCodes(
        logPath,
        purpose: 'restore_account',
      ))
          .length;
      final pending = await _pendingLogin(owner);
      await owner.auth.restore(
        ticket: pending.details!['restore_ticket']! as String,
        code: await latestVerificationCode(
          logPath,
          after: known,
          purpose: 'restore_account',
        ),
      );
      await owner.sync();
      expect(await medicationsOf(owner, self), contains(med.id));

      // Relatives regain access without a new invite: the viewer's scope
      // comes back, the guardian's archive becomes writable again.
      await viewer.sync();
      await guardian.sync();
      expect(await roleOf(viewer, self), 'viewer');
      expect((await medicationsOf(viewer, self))[med.id]!.name, med.name);
      expect(await eventOf(viewer, med.eventId), isNotNull);
      expect(await roleOf(guardian, ward), 'guardian');
      expect(await _isArchived(guardian, ward), isFalse);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

/// What a viewer or editor holds of [self]: `shared` in full, `anonymous`
/// without name, notes, doses and intake notes, `hidden` not at all.
Future<void> _expectProjection(
  Device relative,
  String self,
  Map<String, Medication> meds,
) async {
  final seen = await medicationsOf(relative, self);
  expect(
    seen.keys,
    unorderedEquals([meds['shared']!.id, meds['anonymous']!.id]),
    reason: 'a hidden medication never reaches a relative',
  );
  final shared = seen[meds['shared']!.id]!;
  expect(shared.name, meds['shared']!.name);
  expect(shared.notes, meds['shared']!.note);
  expect(shared.redacted, isFalse);
  final anonymous = seen[meds['anonymous']!.id]!;
  expect(anonymous.redacted, isTrue);
  expect(anonymous.name, isNull);
  expect(anonymous.notes, isNull);

  final sharedSchedule = await schedulesOf(relative, meds['shared']!.id);
  expect(sharedSchedule.single.redacted, isFalse);
  expect(sharedSchedule.single.rule, contains('tablet'));
  final anonymousSchedule = await schedulesOf(relative, meds['anonymous']!.id);
  expect(anonymousSchedule.single.redacted, isTrue);
  expect(anonymousSchedule.single.rule, isNot(contains('tablet')));
  expect(await schedulesOf(relative, meds['hidden']!.id), isEmpty);

  final sharedEvent = await eventOf(relative, meds['shared']!.eventId);
  expect(sharedEvent!.eventType, 'taken');
  expect(sharedEvent.note, isNull, reason: 'notes of intakes stay private');
  final anonymousEvent = await eventOf(relative, meds['anonymous']!.eventId);
  expect(anonymousEvent!.eventType, 'taken', reason: 'time and status');
  expect(await eventOf(relative, meds['hidden']!.eventId), isNull);
}

/// A viewer's edit of a shared medication is refused and the server's name
/// comes back; the queue is empty afterwards.
Future<void> _viewerCannotWrite(
  Device viewer,
  Device owner,
  String self,
  Medication shared,
) async {
  await viewer.medications.update(
    shared.id,
    const MedicationDraft(name: 'Viewer edit', notes: 'viewer note'),
  );
  await viewer.sync();
  expect(
    (await medicationsOf(viewer, self))[shared.id]!.name,
    shared.name,
    reason: 'the refused edit is replaced by the server state',
  );
  await owner.sync();
  expect((await medicationsOf(owner, self))[shared.id]!.name, shared.name);
}

/// An editor edits a `shared` medication (the owner receives it) but cannot
/// mark a dose: the server refuses and the local mark goes.
Future<void> _editorWrites(
  Device editor,
  Device owner,
  String self,
  Map<String, Medication> meds,
) async {
  final shared = meds['shared']!;
  await editor.medications.update(
    shared.id,
    MedicationDraft(
      name: 'Edited by editor',
      notes: shared.note,
    ),
  );
  final mark = await editor.doseEvents.record(
    medicationId: shared.id,
    type: DoseEventType.taken,
    at: DateTime.now().toUtc(),
    occurrence: OccurrenceRef(
      scheduleId: shared.scheduleId,
      localDate: nextDay,
      localTime: intakeTime,
    ),
  );
  final eventsBefore = await eventCountOf(owner, self);
  await editor.sync();
  await owner.sync();

  expect(
    (await medicationsOf(owner, self))[shared.id]!.name,
    'Edited by editor',
    reason: 'an editor edits shared medications',
  );
  expect(
    await eventOf(editor, mark),
    isNull,
    reason: 'an editor cannot mark doses: the refused mark is dropped',
  );
  expect(await eventOf(owner, mark), isNull);
  expect(await eventCountOf(owner, self), eventsBefore);
  expect(await editor.db.select(editor.db.outbox).get(), isEmpty);
}

/// A guardian marks a dose of the managed profile; the owner receives it.
Future<void> _guardianMarks(
  Device guardian,
  Device owner,
  String ward,
  Medication wardMed,
) async {
  final mark = await guardian.doseEvents.record(
    medicationId: wardMed.id,
    type: DoseEventType.taken,
    at: DateTime.now().toUtc(),
    occurrence: OccurrenceRef(
      scheduleId: wardMed.scheduleId,
      localDate: nextDay,
      localTime: intakeTime,
    ),
  );
  await guardian.sync();
  await owner.sync();
  expect(await eventOf(owner, mark), isNotNull);
}

/// The owner revokes every grant they gave.
Future<void> _revokeAll(Device owner) async {
  final listed = await owner.request('GET', '/v1/grants');
  final outgoing = decodeBody(listed.body)['outgoing']! as List<Object?>;
  expect(outgoing, hasLength(3));
  for (final grant in outgoing) {
    final id = (grant! as Map<String, Object?>)['id']!;
    final revoked = await owner.request('DELETE', '/v1/grants/$id');
    expect(revoked.statusCode, 204);
  }
}

/// Signs in to the pending account: refused with the restore ticket.
Future<ApiException> _pendingLogin(Device owner) async {
  try {
    await owner.auth.login(email: owner.email, password: e2ePassword);
  } on ApiException catch (error) {
    expect(error.code, 'account_pending_deletion');
    expect(error.details, isNotNull);
    return error;
  }
  throw StateError('a pending account must not sign in');
}

Future<bool> _isArchived(Device device, String profileId) async {
  final scope = await (device.db.select(device.db.accessScopes)
        ..where((row) => row.profileId.equals(profileId)))
      .getSingle();
  return scope.archived;
}
