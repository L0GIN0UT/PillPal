import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/reminders/reminder_settings_sections.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../helpers.dart';
import 'family_fixtures.dart';

// What the medication and schedule forms offer follows the role on the
// medication's profile (ADR 0005 §2, D3).

class _Seeded {
  _Seeded(this.profile, this.medication, this.schedule);

  final String profile;
  final String medication;
  final String schedule;
}

Future<_Seeded> _open(
  WidgetTester tester,
  String location, {
  String role = 'editor',
  String kind = 'self',
  String privacy = 'shared',
  bool archived = false,
}) async {
  final harness = TestHarness();
  final container = createContainer(harness);
  await harness.seedSelfProfile();
  final profile = await seedProfile(
    harness,
    role: role,
    kind: kind,
    archived: archived,
  );
  final ids = await seedForeignMedication(
    harness,
    container,
    profile,
    privacy: privacy,
  );
  await pumpApp(tester, harness: harness, container: container);
  final seeded = _Seeded(profile, ids.medication, ids.schedule);
  openRoute(
    container,
    location
        .replaceAll('{medication}', seeded.medication)
        .replaceAll('{schedule}', seeded.schedule)
        .replaceAll('{profile}', seeded.profile),
  );
  await tester.pumpAndSettle();
  return seeded;
}

const String _editMedication = '/medication/{medication}';
const String _editSchedule = '/medication/{medication}/schedule/{schedule}';

void main() {
  group('medication form', () {
    testWidgets('an editor edits a shared medication but not its privacy',
        (tester) async {
      await _open(tester, _editMedication);

      expect(find.byKey(const Key('med-save')), findsOneWidget);
      expect(find.byKey(const Key('med-delete')), findsNothing);
      expect(find.byKey(const ValueKey('privacy-hidden')), findsNothing);
      expect(find.byKey(const Key('privacy-editor-note')), findsOneWidget);
      // Reminders of someone else's medication are not the editor's.
      expect(find.byType(MedicationReminderSection), findsNothing);
    });

    for (final privacy in ['anonymous', 'hidden']) {
      testWidgets('an editor cannot open a $privacy medication',
          (tester) async {
        await _open(tester, _editMedication, privacy: privacy);

        expect(find.text('You cannot change this medication.'), findsOneWidget);
        expect(find.byKey(const Key('med-save')), findsNothing);
      });
    }

    testWidgets('a viewer gets no form', (tester) async {
      await _open(tester, _editMedication, role: 'viewer');

      expect(find.text('You cannot change this medication.'), findsOneWidget);
      expect(find.byKey(const Key('med-save')), findsNothing);
    });

    testWidgets('nobody edits an archive', (tester) async {
      await _open(
        tester,
        _editMedication,
        role: 'guardian',
        kind: 'managed',
        archived: true,
      );

      expect(find.text('You cannot change this medication.'), findsOneWidget);
    });

    testWidgets('a guardian has the whole form, reminders included',
        (tester) async {
      await _open(
        tester,
        _editMedication,
        role: 'guardian',
        kind: 'managed',
        privacy: 'hidden',
      );

      expect(find.byKey(const Key('med-delete')), findsOneWidget);
      expect(find.byKey(const ValueKey('privacy-hidden')), findsOneWidget);
      expect(find.byType(MedicationReminderSection), findsOneWidget);
    });

    testWidgets('the privacy choice is explained in words', (tester) async {
      final harness = TestHarness();
      final container = createContainer(harness);
      await harness.seedSelfProfile();
      await pumpApp(tester, harness: harness, container: container);
      openRoute(container, AppRoutes.newMedication);
      await tester.pumpAndSettle();

      expect(
          find.byKey(const ValueKey('privacy-explain-shared')), findsOneWidget);
      expect(
        find.textContaining('name, dose, schedule and every intake'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('privacy-anonymous')));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('privacy-explain-anonymous')),
        findsOneWidget,
      );
      expect(find.textContaining('as "Medication"'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('privacy-hidden')));
      await tester.pump();
      expect(find.textContaining('Relatives see nothing'), findsOneWidget);
    });
  });

  group('new medication of another profile', () {
    testWidgets('an editor adds one that is shared, without a privacy choice',
        (tester) async {
      final harness = TestHarness();
      final container = createContainer(harness);
      await harness.seedSelfProfile();
      final profile = await seedProfile(harness, role: 'editor');
      await pumpApp(tester, harness: harness, container: container);
      openRoute(container, AppRoutes.newProfileMedication(profile));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('privacy-hidden')), findsNothing);
      await tester.enterText(find.byKey(const Key('med-name')), 'Med C');
      await tester.tap(find.byKey(const Key('med-save')));
      await tester.pumpAndSettle();

      final rows = await harness.db.select(harness.db.medications).get();
      expect(rows.single.name, 'Med C');
      expect(rows.single.profileId, profile);
      expect(rows.single.privacy, 'shared');
    });

    testWidgets('a viewer cannot add', (tester) async {
      final harness = TestHarness();
      final container = createContainer(harness);
      await harness.seedSelfProfile();
      final profile = await seedProfile(harness, role: 'viewer');
      await pumpApp(tester, harness: harness, container: container);
      openRoute(container, AppRoutes.newProfileMedication(profile));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('med-save')), findsNothing);
      expect(find.text('You cannot change this medication.'), findsOneWidget);
    });

    testWidgets('a guardian adds one to a managed profile', (tester) async {
      final harness = TestHarness();
      final container = createContainer(harness);
      await harness.seedSelfProfile();
      final profile = await seedProfile(
        harness,
        role: 'guardian',
        kind: 'managed',
      );
      await pumpApp(tester, harness: harness, container: container);
      openRoute(container, AppRoutes.newProfileMedication(profile));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('privacy-hidden')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('med-name')), 'Med D');
      await tester.tap(find.byKey(const ValueKey('privacy-hidden')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('med-save')));
      await tester.pumpAndSettle();

      final rows = await harness.db.select(harness.db.medications).get();
      expect(rows.single.profileId, profile);
      expect(rows.single.privacy, 'hidden');
    });
  });

  group('schedule editor', () {
    testWidgets('an editor changes a schedule but cannot delete it',
        (tester) async {
      await _open(tester, _editSchedule);

      expect(find.byKey(const Key('schedule-save')), findsOneWidget);
      expect(find.byKey(const Key('schedule-delete')), findsNothing);
    });

    testWidgets('a guardian can delete it', (tester) async {
      await _open(
        tester,
        _editSchedule,
        role: 'guardian',
        kind: 'managed',
      );

      expect(find.byKey(const Key('schedule-delete')), findsOneWidget);
    });

    testWidgets('a viewer cannot open it', (tester) async {
      await _open(tester, _editSchedule, role: 'viewer');

      expect(find.byKey(const Key('schedule-save')), findsNothing);
      expect(find.text('You cannot change this medication.'), findsOneWidget);
    });
  });
}
