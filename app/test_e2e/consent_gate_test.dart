import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/repositories/dose_events_repository.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/data/sync/sync_engine.dart';
import 'package:pillpal/src/features/consent/consent_documents.dart';
import 'package:pillpal_core/pillpal_core.dart';

import 'device.dart';

// End-to-end (CI job "app / e2e"): the re-consent gate (ADR 0016 §5) against
// the real backend. An account that registered without consents (the CI
// backend does not require them yet) keeps working locally, sends nothing
// until it accepts, and then a second device sees everything it made.
// Needs PILLPAL_E2E_BASE_URL and PILLPAL_E2E_LOG; skipped otherwise.

Map<String, Object?> _rule() => {
      'v': 1,
      'kind': 'daily',
      'start_date': '2026-10-01',
      'end_date': null,
      'times': [
        {
          'time': '08:00',
          'dose': {'amount': '1', 'unit': 'tablet'},
        },
      ],
    };

void main() {
  final baseUrl = Platform.environment['PILLPAL_E2E_BASE_URL'];
  final logPath = Platform.environment['PILLPAL_E2E_LOG'];
  final skip = baseUrl == null || logPath == null
      ? 'PILLPAL_E2E_BASE_URL / PILLPAL_E2E_LOG not set'
      : null;

  test(
    'no medical sync until the health data consent is given',
    () async {
      final a = Device(Uri.parse(baseUrl!));
      final b = Device(Uri.parse(baseUrl));
      addTearDown(a.close);
      addTearDown(b.close);
      final email = 'e2e-${DateTime.now().microsecondsSinceEpoch}@example.com';
      const password = 'e2e-password-1';

      // The CI server does not require consents at registration: the account
      // has none, like one created before consents existed.
      final user = await a.signUp(
        email: email,
        password: password,
        logPath: logPath!,
        withConsents: false,
      );
      final features =
          jsonDecode((await a.request('GET', '/v1/me/features')).body)
              as Map<String, Object?>;
      expect(features['consent_required_kinds'], isEmpty);
      final missing = (await a.consents.get(userId: user)).missing;
      expect(missing, containsAll(['health_data', 'terms', 'privacy']));

      // Local work goes on: a profile, a medication, a schedule, a dose.
      final grandma =
          await a.profiles.create(displayName: 'Grandma', timezone: 'UTC');
      final vitamin = await a.medications.create(
        profileId: grandma,
        draft: const MedicationDraft(name: 'Vitamin D', stockCount: '30'),
      );
      final morning =
          await a.schedules.create(medicationId: vitamin, rule: _rule());
      await a.doseEvents.record(
        medicationId: vitamin,
        type: DoseEventType.taken,
        at: DateTime.now().toUtc(),
        occurrence: OccurrenceRef(
          scheduleId: morning,
          localDate: LocalDate(2026, 10, 16),
          localTime: '08:00',
        ),
      );
      final waiting = await a.db.select(a.db.outbox).get();
      expect(waiting, hasLength(4));

      // Paused: the run ends `consent_required`, and the server has none of it.
      final paused = await a.engine.sync();
      expect(paused.errorCode, SyncEngine.consentPaused);
      expect(await a.syncState.consentMissing(), contains('health_data'));
      expect(await a.db.select(a.db.outbox).get(), waiting);
      expect(
          (await a.request('GET', '/v1/medications/$vitamin')).statusCode, 404);

      // The screen records the three texts, one after another, and stores
      // the server's answer.
      for (final grant in ConsentDocuments.grantsFor('ru')) {
        await a.consents.accept(grant, userId: user);
      }
      final left = (await a.consents.get(userId: user)).missing;
      expect(left, isEmpty);
      await a.syncState.saveConsentMissing(user, left);

      // Resumed: the whole outbox goes out in its order.
      await a.sync();
      expect(await a.db.select(a.db.outbox).get(), isEmpty);
      expect(
          (await a.request('GET', '/v1/medications/$vitamin')).statusCode, 200);

      // A second device of the account asks once, is allowed and converges.
      await b.auth.login(email: email, password: password);
      await b.sync();
      expect(await b.snapshot(), await a.snapshot());
      expect((await b.snapshot())['medications'], hasLength(1));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
