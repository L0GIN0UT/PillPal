import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/features/reminders/level_migrated_banner.dart';
import 'package:pillpal/src/localization_delegates.dart';
import 'package:pillpal/src/reminders/providers.dart';
import 'package:pillpal/src/reminders/reminder_settings_repository.dart';

// The one-time notice after the reminder level became app-wide (Q2).

class _Repository implements ReminderSettingsRepository {
  int dismissed = 0;

  @override
  Future<void> dismissLevelMigrationNotice() async => dismissed++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _host(_Repository repository, {required bool pending}) => ProviderScope(
      overrides: [
        reminderSettingsRepositoryProvider.overrideWithValue(repository),
        reminderLevelMigratedProvider
            .overrideWith((ref) => Stream.value(pending)),
      ],
      child: const MaterialApp(
        locale: Locale('ru'),
        localizationsDelegates: pillPalLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: LevelMigratedBanner()),
      ),
    );

void main() {
  testWidgets('shows the notice and dismisses it', (tester) async {
    final repository = _Repository();
    await tester.pumpWidget(_host(repository, pending: true));
    await tester.pump();

    expect(find.byKey(const Key('reminder-level-migrated')), findsOneWidget);
    expect(
      find.text(
        'Уровень напоминаний теперь общий для всех лекарств. '
        'Изменить можно в настройках.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('reminder-level-migrated-dismiss')));
    expect(repository.dismissed, 1);
  });

  testWidgets('shows nothing when there is nothing to tell', (tester) async {
    await tester.pumpWidget(_host(_Repository(), pending: false));
    await tester.pump();

    expect(find.byKey(const Key('reminder-level-migrated')), findsNothing);
  });
}
