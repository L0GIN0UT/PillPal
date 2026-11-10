import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/data/api/account_dto.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/features/common/pillpal_card.dart';
import 'package:pillpal/src/features/common/status_pill.dart';
import 'package:pillpal/src/features/family/family_overview.dart';
import 'package:pillpal/src/features/family/family_screen.dart';
import 'package:pillpal/src/routing/routes.dart';
import 'package:pillpal/src/theme/app_theme.dart';
import 'package:pillpal/src/theme/palette.dart';

import '../support/family_tab_fixtures.dart';

// The Family tab in the «Забота» look (boards B-Family, B2-EmptyFamily): rows
// in cards with 48 avatars, an invite button in the header, the empty state
// with two actions. The matrix is in family_ui_matrix_test.dart.

/// Pumps the tab in a router whose other routes only record where they went.
Future<List<String>> _pump(
  WidgetTester tester, {
  FamilyOverview? overview,
  List<RelativeLinkRow> fresh = const [],
  AccountFeatures features = const AccountFeatures(),
  bool pushHint = true,
}) async {
  final visited = <String>[];
  Widget recorder(GoRouterState state) {
    visited.add(state.uri.path);
    return Scaffold(body: Text('went ${state.uri.path}'));
  }

  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => familyScope(
          const FamilyScreen(),
          overview: overview,
          fresh: fresh,
          features: features,
          pushHint: pushHint,
        ),
      ),
      GoRoute(
        path: '/profile/:id/today',
        builder: (context, state) => recorder(state),
      ),
      GoRoute(
        path: '/family/link/:id',
        builder: (context, state) => recorder(state),
      ),
      GoRoute(
        path: '/family/invite/:id',
        builder: (context, state) => recorder(state),
      ),
    ],
  );
  addTearDown(router.dispose);
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp.router(
      routerConfig: router,
      theme: buildPillPalTheme(brightness: Brightness.light, senior: false),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
    ),
  );
  await tester.pump();
  await tester.pump();
  return visited;
}

void main() {
  const palette = PillPalPalette.light;

  testWidgets('tapping the row of someone I see opens their day',
      (tester) async {
    final visited = await _pump(tester);

    await tester.tap(find.byKey(const ValueKey('link-in-1')));
    await tester.pumpAndSettle();

    expect(visited, [AppRoutes.profileToday('profile-in-1')]);
  });

  testWidgets('tapping the row of a person who sees me opens the link',
      (tester) async {
    final visited = await _pump(tester);

    await tester.tap(find.byKey(const ValueKey('link-out-managed')));
    await tester.pumpAndSettle();

    expect(visited, [AppRoutes.link('out-managed')]);
  });

  testWidgets('the settings icon of a row opens the link', (tester) async {
    final visited = await _pump(tester);

    await tester.tap(find.byKey(const ValueKey('link-settings-in-1')));
    await tester.pumpAndSettle();

    expect(visited, [AppRoutes.link('in-1')]);
  });

  testWidgets('every row is a card with a 48 avatar', (tester) async {
    await _pump(tester);

    for (final key in const [
      'link-new',
      'link-in-1',
      'ward-ward-1',
      'ward-ward-2',
    ]) {
      final row = find.byKey(ValueKey(key));
      expect(
        find.ancestor(of: row, matching: find.byType(PillPalCard)),
        findsOneWidget,
        reason: '$key is in a card',
      );
      final avatar = find.descendant(
        of: row,
        matching: find.byKey(const Key('family-avatar')),
      );
      expect(avatar, findsOneWidget, reason: '$key has an avatar');
      expect(tester.getSize(avatar), const Size.square(PillPalSizes.avatarMd));
    }
  });

  testWidgets('the avatar holds the first letter of the name', (tester) async {
    await _pump(tester);

    final avatar = find.descendant(
      of: find.byKey(const ValueKey('link-in-1')),
      matching: find.byKey(const Key('family-avatar')),
    );
    expect(
      find.descendant(of: avatar, matching: find.text('G')),
      findsOneWidget,
    );
  });

  testWidgets('a paused link says so with an icon and a word', (tester) async {
    await _pump(tester);

    final pill = find.descendant(
      of: find.byKey(const ValueKey('link-out-paused')),
      matching: find.byType(StatusPill),
    );
    expect(pill, findsOneWidget);
    expect(
      find.descendant(of: pill, matching: find.text('not active')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: pill, matching: find.byIcon(Icons.circle_outlined)),
      findsOneWidget,
    );
  });

  testWidgets('the invite button is the primary action of the header',
      (tester) async {
    await _pump(tester);

    final invite = find.byKey(const Key('invite-self'));
    expect(invite, findsOneWidget);
    expect(tester.widget(invite), isA<FilledButton>());
    expect(
      find.descendant(of: invite, matching: find.text('Invite')),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(invite).dy,
      lessThan(tester.getTopLeft(find.text('People I care for')).dy),
    );
  });

  testWidgets('the sections follow the board: wards, I see, see me',
      (tester) async {
    await _pump(tester);

    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    expect(top('People I care for'), lessThan(top('I can see')));
    expect(top('I can see'), lessThan(top('Can see me')));
  });

  testWidgets('at the relatives limit the button gives way to the notice',
      (tester) async {
    await _pump(
      tester,
      features: const AccountFeatures(
        softLimitsEnabled: true,
        relativesLimit: 2,
      ),
      overview: FamilyOverview(
        seeMe: [familyLink('a'), familyLink('b')],
        iSee: const [],
        wards: const [],
      ),
    );

    expect(find.byKey(const Key('invite-self')), findsNothing);
    expect(find.byKey(const Key('relatives-limit')), findsOneWidget);
  });

  group('empty family', () {
    testWidgets('has an invite and an add-ward action', (tester) async {
      await _pump(tester, overview: familyNobody, pushHint: false);

      final invite = find.byKey(const Key('invite-self'));
      final ward = find.byKey(const Key('add-ward'));
      expect(invite, findsOneWidget);
      expect(ward, findsOneWidget);
      expect(tester.widget(invite), isA<FilledButton>());
      expect(tester.widget(ward), isA<OutlinedButton>());
      expect(find.text('No one here yet'), findsOneWidget);
    });

    testWidgets('the invite action opens the invite screen', (tester) async {
      final visited = await _pump(
        tester,
        overview: familyNobody,
        pushHint: false,
      );

      await tester.tap(find.byKey(const Key('invite-self')));
      await tester.pumpAndSettle();

      expect(visited, [AppRoutes.createInvite('self-1')]);
    });

    testWidgets('the accept entry stays reachable', (tester) async {
      await _pump(tester, overview: familyNobody, pushHint: false);

      expect(find.byKey(const Key('accept-invite')), findsOneWidget);
    });
  });

  group('banners', () {
    Color? fillOf(WidgetTester tester, String key) => (tester
            .widgetList<DecoratedBox>(
              find.descendant(
                of: find.byKey(Key(key)),
                matching: find.byType(DecoratedBox),
              ),
            )
            .first
            .decoration as BoxDecoration)
        .color;

    testWidgets('the push hint is neutral, the new-relative one soft',
        (tester) async {
      await _pump(tester, fresh: [familyLink('new', counterpart: 'Alex')]);

      expect(fillOf(tester, 'push-unavailable-hint'), palette.raised);
      expect(fillOf(tester, 'new-relative-banner'), palette.actionSoft);
    });
  });
}
