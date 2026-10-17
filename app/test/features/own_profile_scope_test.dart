import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/features/doses/dose_providers.dart';

import '../data/test_env.dart';
import '../helpers.dart';

// The database holds relatives' rows from milestone 3.6; the screens of the
// user read the own self profile only.

void main() {
  test('schedules and medications of a relative never reach the user screens',
      () async {
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    final own = await harness.seedMedication(container);
    final ownSchedule = await harness.seedSchedule(container, own, dailyRule());
    final relative = await container
        .read(profilesRepositoryProvider)
        .create(displayName: 'Relative', timezone: 'UTC');
    await (harness.db.update(harness.db.accessScopes)
          ..where((row) => row.profileId.equals(relative)))
        .write(const AccessScopesCompanion(role: Value('viewer')));
    final theirs = await container.read(medicationsRepositoryProvider).create(
          profileId: relative,
          draft: const MedicationDraft(name: 'Relative med'),
        );
    await harness.seedSchedule(container, theirs, dailyRule());

    final schedules = await container.read(parsedSchedulesProvider.future);
    final medications = await container.read(selfMedicationsProvider.future);

    expect(schedules.map((s) => s.row.id), [ownSchedule]);
    expect(medications.map((m) => m.id), [own]);
  });
}
