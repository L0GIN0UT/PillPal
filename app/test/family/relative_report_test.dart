import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/report/report_model.dart';
import 'package:pillpal/src/features/report/report_service.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../helpers.dart';
import 'family_fixtures.dart';

// The report of a relative is made from what the server projected for the
// user: no hidden medication exists locally, an anonymous one is flagged and
// the PDF prints it as "Medication" without strength or dose (the flag is
// what `report_pdf.dart` checks).

void main() {
  test('is built from the relative profile only, redacted rows flagged',
      () async {
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    await harness.seedMedication(container, name: 'Own Med');
    final profile = await seedProfile(harness, name: 'Grace');
    await seedForeignMedication(
      harness,
      container,
      profile,
      name: 'Shared Med',
    );
    await seedForeignMedication(
      harness,
      container,
      profile,
      name: 'Leaky Name',
      privacy: 'anonymous',
      redacted: true,
    );

    final report = await container.read(reportServiceProvider).build(
          lastDays(LocalDate(2026, 10, 16), 7),
          profileId: profile,
        );

    expect(report.patientName, 'Grace');
    final lines = report.medications;
    expect(lines, hasLength(2));
    expect(
      [for (final line in lines) line.medication.redacted],
      unorderedEquals([false, true]),
    );
    // Nothing of the user's own profile.
    expect(
      [for (final line in lines) line.medication.name],
      isNot(contains('Own Med')),
    );
  });
}
