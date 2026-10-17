import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/repositories/relatives_repository.dart';

import '../helpers.dart';

/// A JSON response of the fake backend.
http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

/// The error envelope of the backend (`{"error": {...}}`).
http.Response errorResponse(
  int status,
  String code, {
  Map<String, Object?>? details,
}) =>
    jsonResponse({
      'error': {
        'code': code,
        'message': 'synthetic',
        if (details != null) 'details': details,
      },
    }, status);

/// `OutgoingGrantOut`.
Map<String, Object?> outgoingGrantJson({
  required String id,
  String profileId = selfProfileId,
  String role = 'viewer',
  String? grantee = 'Alex Relative',
  bool active = true,
  String profileName = 'Test User',
  String profileKind = 'self',
  String createdAt = '2026-10-10T08:00:00Z',
}) =>
    {
      'id': id,
      'profile_id': profileId,
      'profile_display_name': profileName,
      'profile_kind': profileKind,
      'role': role,
      'grantee_display_name': grantee,
      'active': active,
      'disclosure_version': 1,
      'created_at': createdAt,
    };

/// `IncomingGrantOut`.
Map<String, Object?> incomingGrantJson({
  required String id,
  required String profileId,
  String role = 'viewer',
  String? owner = 'Grace Owner',
  String profileName = 'Grace',
  String profileKind = 'self',
  bool notifyMissed = true,
}) =>
    {
      'id': id,
      'profile_id': profileId,
      'profile_display_name': profileName,
      'profile_kind': profileKind,
      'role': role,
      'owner_display_name': owner,
      'notify_missed': notifyMissed,
      'created_at': '2026-10-11T08:00:00Z',
    };

/// A `GET /v1/grants` answer.
Map<String, Object?> grantsJson({
  List<Map<String, Object?>> outgoing = const [],
  List<Map<String, Object?>> incoming = const [],
}) =>
    {'outgoing': outgoing, 'incoming': incoming};

/// Stores a link the way `GET /v1/grants` was stored by the last refresh.
Future<void> seedLink(
  TestHarness harness, {
  required String id,
  String direction = LinkDirection.outgoing,
  String profileId = selfProfileId,
  String role = 'viewer',
  String? counterpart = 'Alex Relative',
  bool active = true,
  bool notifyMissed = true,
  String profileName = 'Test User',
  String profileKind = 'self',
  DateTime? createdAt,
}) async {
  await harness.db.into(harness.db.relativeLinks).insert(
        RelativeLinksCompanion.insert(
          id: id,
          direction: direction,
          profileId: profileId,
          role: role,
          counterpartName: Value(counterpart),
          active: Value(active),
          notifyMissed: Value(notifyMissed),
          createdAt:
              (createdAt ?? DateTime.utc(2026, 10, 10)).microsecondsSinceEpoch,
          profileName: Value(profileName),
          profileKind: Value(profileKind),
        ),
      );
}

/// Stores another profile and the account's scope on it (a pull does this).
Future<String> seedProfile(
  TestHarness harness, {
  String id = 'foreign-profile-1',
  String kind = 'self',
  String role = 'viewer',
  String name = 'Grace',
  String zone = 'Europe/Berlin',
  bool archived = false,
  DateTime? purgeAfter,
  DateTime? ownerLastSeenAt,
}) async {
  await harness.db.into(harness.db.profiles).insert(
        ProfileRow(
          id: id,
          kind: kind,
          displayName: name,
          timezone: zone,
          clientUpdatedAt: 1,
          updatedByDevice: '',
          missedAlertMinutes: 30,
          missedAlertsEnabled: true,
        ),
      );
  await harness.db.into(harness.db.accessScopes).insert(
        AccessScopesCompanion.insert(
          profileId: id,
          role: role,
          kind: kind,
          archived: Value(archived),
          archivePurgeAfter: Value(purgeAfter?.microsecondsSinceEpoch),
          ownerLastSeenAt: Value(ownerLastSeenAt?.microsecondsSinceEpoch),
        ),
      );
  return id;
}

/// A medication of [profileId] taken daily at 08:00 (local time of the
/// profile); returns `(medication, schedule)`. With [redacted] the rows are
/// stored as the server projects an `anonymous` medication for a relative:
/// flagged, with a rule without doses. [name] stays in the row on purpose:
/// the screens must not show it for a redacted medication.
Future<({String medication, String schedule})> seedForeignMedication(
  TestHarness harness,
  ProviderContainer container,
  String profileId, {
  String name = 'Synthetic Med',
  String privacy = 'shared',
  bool redacted = false,
}) async {
  final db = harness.db;
  final newId = container.read(idGeneratorProvider);
  final medication = newId();
  await db.into(db.medications).insert(
        MedicationsCompanion.insert(
          id: medication,
          profileId: profileId,
          name: Value(name),
          tzMode: 'local',
          privacy: privacy,
          redacted: Value(redacted),
          clientUpdatedAt: 1,
          updatedByDevice: '',
        ),
      );
  final schedule = newId();
  final rule = testRule();
  if (redacted) {
    for (final slot in (rule['times']! as List).cast<Map<String, Object?>>()) {
      slot.remove('dose');
    }
  }
  await db.into(db.schedules).insert(
        SchedulesCompanion.insert(
          id: schedule,
          medicationId: medication,
          rule: jsonEncode(rule),
          redacted: Value(redacted),
          clientUpdatedAt: 1,
          updatedByDevice: '',
        ),
      );
  return (medication: medication, schedule: schedule);
}
