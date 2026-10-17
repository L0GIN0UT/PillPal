import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/api/auth_dto.dart';
import 'package:pillpal/src/data/api/sync_api.dart';
import 'package:pillpal/src/data/api/sync_dto.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/repositories/dose_events_repository.dart';
import 'package:pillpal/src/data/repositories/payloads.dart';
import 'package:pillpal/src/data/sync/server_rows.dart';

import 'test_env.dart';

// Client <-> server contract: every field the client sends or reads for auth
// and sync must exist in spec/openapi.json, the snapshot of the backend's
// OpenAPI document (kept current by backend/tests/test_openapi_snapshot.py).

typedef _Json = Map<String, Object?>;

final _Json _openapi = jsonDecode(
  File('../spec/openapi.json').readAsStringSync(),
) as _Json;

_Json _schema(String name) {
  final components = _openapi['components']! as _Json;
  final schemas = components['schemas']! as _Json;
  final schema = schemas[name];
  expect(schema, isNotNull, reason: 'schema $name is missing');
  return schema! as _Json;
}

Set<String> _properties(String name) =>
    (_schema(name)['properties']! as _Json).keys.toSet();

Set<String> _required(String name) => {
      for (final key in (_schema(name)['required'] as List<Object?>?) ?? [])
        key! as String,
    };

Set<String> _enum(String name, String property) {
  final properties = _schema(name)['properties']! as _Json;
  final values = (properties[property]! as _Json)['enum']! as List<Object?>;
  return {for (final value in values) value! as String};
}

_Json _operation(String path, String method) {
  final paths = _openapi['paths']! as _Json;
  final item = paths[path];
  expect(item, isNotNull, reason: 'path $path is missing');
  final operation = (item! as _Json)[method];
  expect(operation, isNotNull, reason: '$method $path is missing');
  return operation! as _Json;
}

String _requestSchema(String path) {
  final body = _operation(path, 'post')['requestBody']! as _Json;
  final content = body['content']! as _Json;
  final json = content['application/json']! as _Json;
  final ref = (json['schema']! as _Json)[r'$ref']! as String;
  return ref.split('/').last;
}

/// [sent] uses only declared fields and every required one.
void _expectSends(String schema, _Json sent) {
  expect(
    _properties(schema),
    containsAll(sent.keys),
    reason: 'client sends fields unknown to $schema',
  );
  expect(sent.keys, containsAll(_required(schema)), reason: schema);
}

/// Every key the client reads exists in [schema].
void _expectReads(String schema, Set<String> keys) {
  expect(
    _properties(schema),
    containsAll(keys),
    reason: 'client reads fields missing from $schema',
  );
}

void main() {
  group('auth', () {
    test('request bodies match the schemas of their endpoints', () {
      final register = const RegisterRequest(
        email: 'demo@example.com',
        password: 'synthetic-pass',
        region: 'ru',
        locale: 'ru',
        timezone: 'Europe/Samara',
        displayName: 'Demo',
      ).toJson();
      final bodies = <String, _Json>{
        '/v1/auth/register': register,
        '/v1/auth/login': AuthBodies.login('demo@example.com', 'x'),
        '/v1/auth/verify-email':
            AuthBodies.verifyEmail('demo@example.com', '1'),
        '/v1/auth/verify-email/resend':
            AuthBodies.resendVerification('demo@example.com'),
        '/v1/auth/refresh': AuthBodies.refresh('token'),
        '/v1/auth/logout': AuthBodies.refresh('token'),
      };
      for (final entry in bodies.entries) {
        _expectSends(_requestSchema(entry.key), entry.value);
      }
      expect(_operation('/v1/auth/register', 'post')['responses'],
          contains('202'));
    });

    test('responses are read with declared fields', () {
      _expectReads('TokenPair', TokenPair.readKeys);
      _expectReads('UserOut', UserInfo.readKeys);
    });
  });

  group('sync', () {
    test('push request matches PushRequest and Mutation', () {
      final mutation = Mutation(
        entity: SyncEntity.schedule,
        op: SyncOp.upsert,
        id: 'id',
        data: const {},
        clientUpdatedAt: DateTime.utc(2026),
      ).toJson();
      _expectSends('Mutation', mutation);
      _expectSends('PushRequest', {'mutations': <Object?>[]});
      expect(_requestSchema('/v1/sync/push'), 'PushRequest');
      final parameters =
          _operation('/v1/sync/push', 'post')['parameters']! as List<Object?>;
      expect(
        [for (final p in parameters) (p! as _Json)['name']],
        contains('X-Device-ID'),
      );
    });

    test('entity payloads match the *Data schemas', () {
      final payloads = <String, _Json>{
        'ProfileData': profilePayload(
          ProfileRow(
            id: 'p',
            kind: 'managed',
            displayName: 'P',
            timezone: 'UTC',
            clientUpdatedAt: DateTime.utc(2026).microsecondsSinceEpoch,
            updatedByDevice: 'd',
            missedAlertMinutes: 30,
            missedAlertsEnabled: true,
          ),
        ),
        'MedicationData': medicationPayload(
          MedicationRow(
            id: 'm',
            profileId: 'p',
            name: 'M',
            tzMode: 'local',
            privacy: 'shared',
            redacted: false,
            clientUpdatedAt: DateTime.utc(2026).microsecondsSinceEpoch,
            updatedByDevice: 'd',
          ),
        ),
        'ScheduleData': schedulePayload(
          ScheduleRow(
            id: 's',
            medicationId: 'm',
            rule: jsonEncode(dailyRule()),
            redacted: false,
            clientUpdatedAt: DateTime.utc(2026).microsecondsSinceEpoch,
            updatedByDevice: 'd',
          ),
        ),
        'DoseEventData': doseEventPayload(
          DoseEventRow(
            id: 'e',
            profileId: 'p',
            medicationId: 'm',
            eventType: 'taken',
            at: DateTime.utc(2026).microsecondsSinceEpoch,
          ),
        ),
      };
      for (final entry in payloads.entries) {
        _expectSends(entry.key, entry.value);
      }
      final snoozed = doseEventPayload(
        DoseEventRow(
          id: 'e',
          profileId: 'p',
          medicationId: 'm',
          eventType: 'snoozed',
          at: DateTime.utc(2026).microsecondsSinceEpoch,
          snoozeUntil: DateTime.utc(2026, 1, 1, 0, 15).microsecondsSinceEpoch,
        ),
      );
      expect(snoozed, contains('snooze_until'));
      _expectSends('DoseEventData', snoozed);
    });

    test('responses are read with declared fields', () {
      _expectReads('PushResponse', SyncApi.pushResponseKeys);
      _expectReads('MutationResult', MutationResult.readKeys);
      _expectReads('EntityState', EntityState.readKeys);
      _expectReads('Change', Change.readKeys);
      _expectReads('ScopedPullResponse', ScopedPullPage.readKeys);
      _expectReads('ScopeOut', PulledScope.readKeys);
      _expectReads('ProfileOut', profileKeys);
      _expectReads('MedicationOut', medicationKeys);
      _expectReads('ScheduleOut', scheduleKeys);
      _expectReads('DoseEventOut', doseEventKeys);
    });

    test('projected rows are read with the keys of the redacted schemas', () {
      _expectReads('MedicationRedacted', redactedMedicationKeys);
      _expectReads('ScheduleRedacted', redactedScheduleKeys);
      // The rule of a redacted schedule has course dates and times, no doses.
      final rule = _properties('ScheduleRedactedRule');
      expect(rule, containsAll(<String>['kind', 'start_date', 'times']));
      expect(_properties('RedactedSlot'), {'time'});
    });

    test('the scoped pull request matches ScopedPullRequest', () {
      expect(_requestSchema('/v1/sync/pull'), 'ScopedPullRequest');
      _expectSends('ScopedPullRequest', {
        'cursors': <String, int>{},
        'limit': 1,
        'backfill_until': <String, int>{},
      });
      final parameters =
          _operation('/v1/sync/pull', 'post')['parameters']! as List<Object?>;
      expect(
        [for (final p in parameters) (p! as _Json)['name']],
        contains('X-Device-ID'),
      );
    });

    test('reconcile GETs return the *Out schemas the applier reads', () {
      const paths = {
        '/v1/profiles/{profile_id}': 'ProfileOut',
        '/v1/medications/{medication_id}': 'MedicationOut',
        '/v1/schedules/{schedule_id}': 'ScheduleOut',
        '/v1/dose-events/{event_id}': 'DoseEventOut',
      };
      for (final entry in paths.entries) {
        final responses = _operation(entry.key, 'get')['responses']! as _Json;
        final ok = responses['200']! as _Json;
        final content = (ok['content']! as _Json)['application/json']! as _Json;
        final ref = (content['schema']! as _Json)[r'$ref']! as String;
        expect(ref.split('/').last, entry.value);
      }
    });

    test('enum wire values are known to the server', () {
      expect(
        _enum('Mutation', 'entity'),
        {for (final e in SyncEntity.values) e.wire},
      );
      expect(_enum('Mutation', 'op'), {for (final o in SyncOp.values) o.wire});
      expect(
        _enum('MutationResult', 'status'),
        {for (final s in MutationStatus.values) s.wire},
      );
      expect(
        _enum('DoseEventData', 'type'),
        {for (final t in DoseEventType.values) t.wire},
      );
    });

    test('client limits do not exceed the server limits', () {
      final mutations = _schema('PushRequest')['properties']! as _Json;
      expect(
        (mutations['mutations']! as _Json)['maxItems'],
        SyncLimits.pushBatch,
      );
      final request = _schema('ScopedPullRequest')['properties']! as _Json;
      expect(
        (request['limit']! as _Json)['maximum'],
        SyncLimits.pullPage,
      );
      expect(
        (request['cursors']! as _Json)['maxProperties'],
        SyncLimits.pullScopes,
      );
    });
  });
}
