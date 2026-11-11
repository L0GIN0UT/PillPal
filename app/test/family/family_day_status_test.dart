import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/features/common/status_kind.dart';
import 'package:pillpal/src/features/common/status_pill.dart';
import 'package:pillpal/src/features/family/day_status_providers.dart';
import 'package:pillpal/src/features/family/family_screen.dart';
import 'package:pillpal/src/theme/app_theme.dart';

import '../support/family_tab_fixtures.dart';

// The per-person day pills of the Family tab (R9, board B-Family): which rows
// get one, what it says in RU and EN, and that it gives way to a "updated N
// ago" hint when the data is old. Synthetic data; the numbers come from the
// provider override (the real provider is in day_status_provider_test.dart).

Future<void> _pump(
  WidgetTester tester,
  Map<String, ProfileDayStatus> days, {
  String locale = 'en',
}) async {
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildPillPalTheme(brightness: Brightness.light, senior: false),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale(locale),
      home: familyScope(const FamilyScreen(), days: days, pushHint: false),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Finder _pill(String profileId) => find.byKey(Key('day-status-$profileId'));

StatusKind _kind(WidgetTester tester, String profileId) =>
    tester.widget<StatusPill>(_pill(profileId)).kind;

void main() {
  testWidgets('a ward with everything taken says so', (tester) async {
    await _pump(tester, {'ward-1': familyDay(taken: 2)});

    expect(_kind(tester, 'ward-1'), StatusKind.taken);
    expect(
      find.descendant(of: _pill('ward-1'), matching: find.text('All taken')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('day-next-ward-1')), findsNothing);
  });

  testWidgets('a missed dose is the calm missed pill with the next dose',
      (tester) async {
    await _pump(tester, {
      'profile-in-1': familyDay(taken: 1, missed: 1, pending: 1),
    });

    expect(_kind(tester, 'profile-in-1'), StatusKind.missed);
    expect(
      find.descendant(
          of: _pill('profile-in-1'), matching: find.text('1 missed')),
      findsOneWidget,
    );
    // 18:00 UTC in the profile's zone (Moscow).
    expect(find.text('Next dose at 21:00'), findsOneWidget);
  });

  testWidgets('waiting doses read "N of M"', (tester) async {
    await _pump(tester, {'ward-1': familyDay(taken: 1, pending: 1)});

    expect(_kind(tester, 'ward-1'), StatusKind.pending);
    expect(
      find.descendant(of: _pill('ward-1'), matching: find.text('1 of 2')),
      findsOneWidget,
    );
    expect(find.text('Next dose at 21:00'), findsOneWidget);
  });

  testWidgets('a day without doses has no pill and no line', (tester) async {
    await _pump(tester, {'ward-1': familyDay()});

    expect(_pill('ward-1'), findsNothing);
    expect(find.textContaining('Next dose'), findsNothing);
  });

  testWidgets('people who see me never get a day pill', (tester) async {
    // Even if the data were there: an outgoing link says who sees me, not how
    // their day goes.
    await _pump(tester, {
      'profile-new': familyDay(taken: 1),
      'profile-out-managed': familyDay(missed: 1),
      'profile-out-paused': familyDay(pending: 1),
    });

    for (final id in ['new', 'out-managed', 'out-paused']) {
      expect(_pill('profile-$id'), findsNothing, reason: id);
    }
  });

  testWidgets('an archive keeps its own pill', (tester) async {
    await _pump(tester, {'ward-2': familyDay(taken: 3)});

    expect(_pill('ward-2'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('ward-ward-2')),
        matching: find.text('archive'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('old data shows how old, not a status that may be wrong',
      (tester) async {
    await _pump(tester, {
      'profile-in-1': familyDay(
        taken: 1,
        missed: 1,
        pending: 1,
        staleAge: const Duration(hours: 7),
      ),
      'ward-1': familyDay(taken: 1, staleAge: const Duration(days: 3)),
    });

    expect(_pill('profile-in-1'), findsNothing);
    expect(find.text('Updated 7 hours ago'), findsOneWidget);
    expect(find.text('Updated 3 days ago'), findsOneWidget);
    expect(find.textContaining('Next dose'), findsNothing);
  });

  testWidgets('the words are Russian with the right plural', (tester) async {
    await _pump(
      tester,
      {
        'ward-1': familyDay(taken: 2),
        'profile-in-1': familyDay(missed: 2, pending: 1),
      },
      locale: 'ru',
    );

    expect(find.text('Всё принято'), findsOneWidget);
    expect(find.text('2 пропуска'), findsOneWidget);
    expect(find.text('Следующий приём в 21:00'), findsOneWidget);
  });

  testWidgets('the status is an icon and a word for a screen reader',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _pump(tester, {'profile-in-1': familyDay(missed: 1)});

    // A pill is a semantics node of its own, the icon excluded.
    expect(find.bySemanticsLabel('1 missed'), findsOneWidget);
    expect(
      find.descendant(
        of: _pill('profile-in-1'),
        matching: find.byIcon(Icons.history),
      ),
      findsOneWidget,
    );
    handle.dispose();
  });
}
