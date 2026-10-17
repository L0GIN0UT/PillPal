import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/repositories/dose_events_repository.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal_core/pillpal_core.dart';

import 'device.dart';

// End-to-end: two installations of one account against the real backend
// (CI job "app / e2e"). Needs PILLPAL_E2E_BASE_URL and PILLPAL_E2E_LOG (the
// backend's log file, for the verification code); skipped otherwise.

Map<String, Object?> _rule(String time) => {
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

void main() {
  final baseUrl = Platform.environment['PILLPAL_E2E_BASE_URL'];
  final logPath = Platform.environment['PILLPAL_E2E_LOG'];
  final skip = baseUrl == null || logPath == null
      ? 'PILLPAL_E2E_BASE_URL / PILLPAL_E2E_LOG not set'
      : null;

  test(
    'two devices of one account converge',
    () async {
      final a = Device(Uri.parse(baseUrl!));
      final b = Device(Uri.parse(baseUrl));
      addTearDown(a.close);
      addTearDown(b.close);
      final email = 'e2e-${DateTime.now().microsecondsSinceEpoch}@example.com';
      const password = 'e2e-password-1';

      await a.signUp(email: email, password: password, logPath: logPath!);
      await b.auth.login(email: email, password: password);

      // A: the self profile comes from the server; add data under it.
      await a.sync();
      final self = (await a.profiles.watchAll().first).single;
      expect(self.kind, 'self');
      final aspirin = await a.medications.create(
        profileId: self.id,
        draft: const MedicationDraft(name: 'Аспирин', notes: 'after meals'),
      );
      final morning =
          await a.schedules.create(medicationId: aspirin, rule: _rule('08:00'));
      await a.doseEvents.record(
        medicationId: aspirin,
        type: DoseEventType.taken,
        at: DateTime.now().toUtc(),
        occurrence: OccurrenceRef(
          scheduleId: morning,
          localDate: LocalDate(2026, 10, 16),
          localTime: '08:00',
        ),
      );
      final grandma =
          await a.profiles.create(displayName: 'Grandma', timezone: 'UTC');
      final vitamin = await a.medications.create(
        profileId: grandma,
        draft: const MedicationDraft(name: 'Vitamin D', stockCount: '30'),
      );
      await a.sync();

      // B: sees everything, then edits and deletes.
      await b.sync();
      expect(await b.snapshot(), await a.snapshot());
      await b.medications.update(
        aspirin,
        const MedicationDraft(name: 'Аспирин Кардио', notes: null),
      );
      await b.schedules.update(morning, _rule('09:00'));
      await b.sync();

      // A: concurrent edit of a medication whose profile B deletes.
      await a.medications.update(
        vitamin,
        const MedicationDraft(name: 'Vitamin D3', stockCount: '29.5'),
      );
      await b.profiles.delete(grandma);
      await b.sync();
      await a.sync();
      await b.sync();

      final snapshot = await a.snapshot();
      expect(await b.snapshot(), snapshot);
      expect(snapshot['profiles'], hasLength(1)); // deletes are final
      expect(snapshot['medications']!.single, contains('Аспирин Кардио'));
      expect(snapshot['schedules']!.single, contains('09:00'));
      expect(snapshot['dose_events'], hasLength(1));

      // Logout erases the device; signing in again restores from the server.
      await b.auth.logout();
      expect((await b.snapshot())['medications'], isEmpty);
      await b.auth.login(email: email, password: password);
      await b.sync();
      expect(await b.snapshot(), snapshot);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
