import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/app.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/repositories/dose_events_repository.dart';
import 'package:pillpal/src/home_widget/home_widget_scope.dart';
import 'package:pillpal/src/home_widget/home_widget_updater.dart';
import 'package:pillpal/src/home_widget/today_widget_snapshot.dart';
import 'package:pillpal/src/reminders/providers.dart';
import 'package:pillpal/src/routing/router.dart';
import 'package:pillpal/src/settings/app_settings.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../helpers.dart';
import 'fake_home_widget_channel.dart';

/// Shared "Med W" at 08:00 and 20:00, hidden "Med X" at 12:00 and 21:00
/// (now: Oct 16 10:00, UTC+4). The 08:00 dose is taken.
Future<ProviderContainer> _seed(TestHarness harness) async {
  final container = createContainer(harness);
  await harness.seedSelfProfile();
  final shared = await harness.seedMedication(
    container,
    name: 'Med W',
    strength: '5 mg',
  );
  final schedule = await harness.seedSchedule(
    container,
    shared,
    testRule(times: ['08:00', '20:00']),
  );
  final hidden = await harness.seedMedication(
    container,
    name: 'Med X',
    privacy: 'hidden',
  );
  await harness.seedSchedule(
    container,
    hidden,
    testRule(times: ['12:00', '21:00']),
  );
  await container.read(doseEventsRepositoryProvider).record(
        medicationId: shared,
        type: DoseEventType.taken,
        at: DateTime.utc(2026, 10, 16, 4, 5),
        occurrence: OccurrenceRef(
          scheduleId: schedule,
          localDate: LocalDate(2026, 10, 16),
          localTime: '08:00',
        ),
      );
  return container;
}

List<List<String>> _lines(FakeHomeWidgetChannel channel, String key) => [
      for (final line in channel.stored[key]!.split(widgetEntrySeparator))
        line.split(widgetFieldSeparator),
    ];

void main() {
  test('open doses of today and tomorrow, privacy-aware, per-day progress',
      () async {
    final channel = FakeHomeWidgetChannel();
    final harness = TestHarness(homeWidget: channel);
    final container = await _seed(harness);
    container.read(settingsProvider.notifier).setLocale(const Locale('ru'));

    await container.read(homeWidgetUpdaterProvider).refresh();

    String ms(int day, int hour) =>
        '${DateTime.utc(2026, 10, day, hour).millisecondsSinceEpoch}';
    expect(channel.stored[TodayWidgetKeys.nextLabel], 'Следующий приём');
    expect(_lines(channel, TodayWidgetKeys.days), [
      [ms(15, 20), ms(16, 20), '1 из 4 сегодня'],
      [ms(16, 20), ms(17, 20), '0 из 4 сегодня'],
    ]);
    expect(_lines(channel, TodayWidgetKeys.entries), [
      [ms(16, 8), '12:00', 'Приём лекарства'],
      [ms(16, 16), '20:00', 'Med W 5 mg'],
      [ms(16, 17), '21:00', 'Приём лекарства'],
      // Tomorrow, so the widget stays right after midnight.
      [ms(17, 4), '08:00', 'Med W 5 mg'],
      [ms(17, 8), '12:00', 'Приём лекарства'],
      [ms(17, 16), '20:00', 'Med W 5 mg'],
      [ms(17, 17), '21:00', 'Приём лекарства'],
    ]);
    expect(channel.stored[TodayWidgetKeys.validUntil], ms(17, 20));
    expect(channel.redraws, 1);
  });

  test('hiding names in notifications hides them on the widget too', () async {
    final channel = FakeHomeWidgetChannel();
    final harness = TestHarness(homeWidget: channel);
    final container = await _seed(harness);
    await container
        .read(reminderSettingsRepositoryProvider)
        .setHideMedicationNames(hide: true);

    await container.read(homeWidgetUpdaterProvider).refresh();

    expect(_lines(channel, TodayWidgetKeys.days).first[2], '1 of 4 today');
    expect(
      _lines(channel, TodayWidgetKeys.entries).map((entry) => entry[2]),
      everyElement('Medication dose'),
    );
  });

  test('without a placed widget its data is removed', () async {
    final channel = FakeHomeWidgetChannel();
    final harness = TestHarness(homeWidget: channel);
    final container = await _seed(harness);
    await container.read(homeWidgetUpdaterProvider).refresh();
    expect(channel.stored, isNotEmpty);

    channel.installed = false;
    await container.read(homeWidgetUpdaterProvider).refresh();
    expect(channel.stored, isEmpty);
  });

  test('without the platform nothing is written', () async {
    final channel = FakeHomeWidgetChannel(supported: false);
    final harness = TestHarness(homeWidget: channel);
    final container = await _seed(harness);
    await container.read(homeWidgetUpdaterProvider).refresh();
    expect(channel.stored, isEmpty);
    expect(channel.redraws, 0);
  });

  testWidgets('a tap on the widget opens Today', (tester) async {
    final channel = FakeHomeWidgetChannel();
    final harness = TestHarness(homeWidget: channel);
    final container = await _seed(harness);
    useTallPhoneSurface(tester);
    container.read(settingsProvider.notifier).setLocale(const Locale('en'));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const HomeWidgetScope(child: PillPalApp()),
      ),
    );
    await tester.pumpAndSettle();
    container.read(routerProvider).go(AppRoutes.history);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('history-pdf')), findsOneWidget);

    channel.tap();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('today-list')), findsOneWidget);
  });
}
