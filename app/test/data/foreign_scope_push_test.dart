import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';

import 'fake_server.dart';
import 'scope_fixtures.dart';
import 'sync_fixtures.dart';
import 'test_env.dart';

// How rejected writes into someone else's scope are settled (ADR 0006 §7):
// never over REST, never with tombstones.

Json _current(Json data) => {
      'op': 'upsert',
      'data': data,
      'client_updated_at': null,
      'updated_by_device': null,
      'deleted_at': null,
    };

void main() {
  late TestEnv env;
  late RelativeIds ids;

  setUp(() async {
    env = await TestEnv.create();
    ids = seedRelative(env, role: 'editor');
    await env.engine.sync();
    await env.medications
        .update(ids.medication, const MedicationDraft(name: 'My edit'));
    expect(await env.outbox(), hasLength(1));
  });
  tearDown(() => env.dispose());

  Iterable<String> restPaths() =>
      env.server.requests.map((r) => r.path).where((p) => p != '/v1/sync/pull');

  test('forbidden_field adopts the projected current and drops the edit',
      () async {
    final current = _current(medicationOut(ids.profile, name: 'Server name'));
    env.server.responder =
        (m) => rejected(m, 'forbidden_field', current: current);

    final report = await env.engine.sync();

    expect(report.adopted, 1);
    expect((await env.medications.find(ids.medication))!.name, 'Server name');
    expect(await env.outbox(), isEmpty);
    expect(restPaths().where((p) => p.startsWith('/v1/medications')), isEmpty);
  });

  test('not_found hard-evicts the entity and its children', () async {
    env.server.responder = (m) => rejected(m, 'not_found');

    await env.engine.sync();

    expect(await env.medications.find(ids.medication), isNull,
        reason: 'hard delete: no tombstone in a foreign scope');
    expect(await env.schedules.find(ids.schedule), isNull);
    expect(await env.outbox(), isEmpty);
    expect(restPaths().where((p) => p.startsWith('/v1/medications')), isEmpty);
  });

  test('another rejection parks the entry and keeps the row', () async {
    env.server.responder = (m) => rejected(m, 'validation_error');

    final report = await env.engine.sync();

    expect(report.parked, 1);
    final entries = await env.outbox();
    expect(entries.single.parked, isTrue);
    expect(entries.single.lastError, 'validation_error');
    expect((await env.medications.find(ids.medication))!.name, 'My edit');
    expect(restPaths().where((p) => p.startsWith('/v1/medications')), isEmpty);
  });

  test('a refusal drops only its own entry: the children keep theirs',
      () async {
    await env.schedules.update(ids.schedule, dailyRule(time: '10:00'));
    expect(await env.outbox(), hasLength(2));
    final current = _current(medicationOut(ids.profile, name: 'Server name'));
    env.server.responder = (m) => m['entity'] == 'medication'
        ? rejected(m, 'forbidden_field', current: current)
        : rejected(m, 'validation_error');

    await env.engine.sync();

    expect((await env.medications.find(ids.medication))!.name, 'Server name');
    final left = await env.outbox();
    expect(left.single.entityId, ids.schedule,
        reason: 'the refusal of the medication left the schedule entry alone');
    expect(left.single.lastError, 'validation_error');
  });

  test('a refused entity with newer edits waiting settles on the last one',
      () async {
    await env.medications
        .update(ids.medication, const MedicationDraft(name: 'My second edit'));
    expect(await env.outbox(), hasLength(2));
    final current = _current(medicationOut(ids.profile, name: 'Server name'));
    env.server.responder =
        (m) => rejected(m, 'forbidden_field', current: current);

    await env.engine.sync();

    expect((await env.medications.find(ids.medication))!.name, 'Server name');
    expect(await env.outbox(), isEmpty);
  });
}
