import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/clock.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/repositories/dose_events_repository.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal_core/pillpal_core.dart';

import 'device.dart';

// Shared steps of the relatives e2e tests: accounts, invites and what a
// device holds locally. Not a test file (no `_test` suffix).

const String e2ePassword = 'e2e-password-1';

/// The privacy levels of a medication (ADR 0005).
const List<String> privacyLevels = ['shared', 'anonymous', 'hidden'];

/// The day of the recorded intakes: inside the schedule's course.
final LocalDate intakeDay = LocalDate(2026, 10, 16);

/// The day after: marks by roles that may or may not write them.
final LocalDate nextDay = LocalDate(2026, 10, 17);

const String intakeTime = '08:00';

Map<String, Object?> dailyRule(String time) => {
      'v': 1,
      'kind': 'daily',
      'start_date': '2026-10-01',
      'end_date': null,
      'times': [
        {
          'time': time,
          'dose': {'amount': '1', 'unit': 'tablet'},
        },
      ],
    };

Map<String, Object?> decodeBody(String body) =>
    jsonDecode(body) as Map<String, Object?>;

/// A new verified account on its own in-memory device.
Future<Device> signedUpDevice(
  Uri baseUrl,
  String logPath,
  String label,
) async {
  final device = Device(baseUrl);
  addTearDown(device.close);
  final stamp = DateTime.now().microsecondsSinceEpoch;
  await device.signUp(
    email: 'e2e-$label-$stamp@example.com',
    password: e2ePassword,
    logPath: logPath,
  );
  await device.sync();
  return device;
}

/// A medication of [privacy] with a daily schedule and one `taken` intake
/// carrying a note, as its owner (or a guardian) writes them.
class Medication {
  const Medication(this.id, this.scheduleId, this.eventId, this.privacy);

  final String id;
  final String scheduleId;
  final String eventId;
  final String privacy;

  String get name => 'Med $privacy';

  String get note => 'note $privacy';
}

Future<Medication> addMedication(
  Device writer,
  String profileId,
  String privacy,
) async {
  final id = await writer.medications.create(
    profileId: profileId,
    draft: MedicationDraft(
      name: 'Med $privacy',
      notes: 'note $privacy',
      privacy: privacy,
    ),
  );
  final scheduleId = await writer.schedules.create(
    medicationId: id,
    rule: dailyRule(intakeTime),
  );
  final eventId = await writer.doseEvents.record(
    medicationId: id,
    type: DoseEventType.taken,
    at: DateTime.now().toUtc(),
    occurrence: OccurrenceRef(
      scheduleId: scheduleId,
      localDate: intakeDay,
      localTime: intakeTime,
    ),
    note: 'note $privacy',
  );
  return Medication(id, scheduleId, eventId, privacy);
}

/// Creates an invite of [role] on [profileId] and returns its token (the URL
/// fragment: the link travels outside the app).
Future<String> createInvite(Device owner, String profileId, String role) async {
  final response = await owner.request(
    'POST',
    '/v1/profiles/$profileId/invites',
    body: {'id': newUuid(), 'role': role, 'disclosure_version': 1},
  );
  expect(response.statusCode, 201, reason: 'invite of role $role');
  final url = decodeBody(response.body)['url']! as String;
  return Uri.parse(url).fragment;
}

/// Invites and accepts: [relative] holds [role] on [profileId] afterwards
/// (after its next sync).
Future<void> link(
  Device owner,
  String profileId,
  String role,
  Device relative,
) async {
  final token = await createInvite(owner, profileId, role);
  final accepted = await relative.request(
    'POST',
    '/v1/invites/accept',
    body: {'token': token},
  );
  expect(accepted.statusCode, 201, reason: 'accept of role $role');
}

Future<String?> roleOf(Device device, String profileId) async {
  final scope = await (device.db.select(device.db.accessScopes)
        ..where((row) => row.profileId.equals(profileId)))
      .getSingleOrNull();
  return scope?.role;
}

Future<Map<String, MedicationRow>> medicationsOf(
  Device device,
  String profileId,
) async {
  final rows = await (device.db.select(device.db.medications)
        ..where(
          (row) => row.profileId.equals(profileId) & row.deletedAt.isNull(),
        ))
      .get();
  return {for (final row in rows) row.id: row};
}

Future<List<ScheduleRow>> schedulesOf(Device device, String medicationId) {
  return (device.db.select(device.db.schedules)
        ..where((row) => row.medicationId.equals(medicationId)))
      .get();
}

Future<DoseEventRow?> eventOf(Device device, String eventId) {
  return (device.db.select(device.db.doseEvents)
        ..where((row) => row.id.equals(eventId)))
      .getSingleOrNull();
}

Future<int> eventCountOf(Device device, String profileId) async {
  final rows = await (device.db.select(device.db.doseEvents)
        ..where((row) => row.profileId.equals(profileId)))
      .get();
  return rows.length;
}

/// The device holds nothing of [profileId]: scope, profile, medications,
/// schedules, dose events and queued writes are all gone.
Future<void> expectEvicted(
  Device device,
  String profileId,
  Iterable<String> medicationIds,
) async {
  expect(await roleOf(device, profileId), isNull, reason: 'scope row');
  expect(
    await (device.db.select(device.db.profiles)
          ..where((row) => row.id.equals(profileId)))
        .get(),
    isEmpty,
    reason: 'profile row',
  );
  expect(
    await (device.db.select(device.db.medications)
          ..where((row) => row.profileId.equals(profileId)))
        .get(),
    isEmpty,
    reason: 'medications',
  );
  expect(await eventCountOf(device, profileId), 0, reason: 'dose events');
  for (final id in medicationIds) {
    expect(await schedulesOf(device, id), isEmpty, reason: 'schedules');
  }
  expect(
    (await device.db.select(device.db.outbox).get())
        .where((entry) => entry.profileId == profileId),
    isEmpty,
    reason: 'queued writes',
  );
}
