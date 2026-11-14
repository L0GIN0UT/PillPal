import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/data/api/account_dto.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/repositories/relatives_repository.dart';
import 'package:pillpal/src/features/common/pillpal_card.dart';
import 'package:pillpal/src/features/common/status_pill.dart';
import 'package:pillpal/src/features/family/family_overview.dart';
import 'package:pillpal/src/features/family/family_screen.dart';
import 'package:pillpal/src/localization_delegates.dart';
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
  List<String>? calls,
  bool senior = false,
  double textScale = 1,
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
          calls: calls,
        ),
      ),
      GoRoute(
        path: '/profile/:id/today',
        builder: (context, state) => recorder(state),
      ),
      GoRoute(
        path: '/family/relative/:id',
        builder: (context, state) => recorder(state),
      ),
      GoRoute(
        path: AppRoutes.addRelative,
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
      theme: buildPillPalTheme(brightness: Brightness.light, senior: senior),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      localizationsDelegates: pillPalLocalizationsDelegates,
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

    await tester.tap(find.byKey(const ValueKey('relative-profile-in-1')));
    await tester.pumpAndSettle();

    expect(visited, [AppRoutes.profileToday('profile-in-1')]);
  });

  testWidgets('tapping a ward opens their day', (tester) async {
    final visited = await _pump(tester);

    await tester.tap(find.byKey(const ValueKey('relative-ward-1')));
    await tester.pumpAndSettle();

    expect(visited, [AppRoutes.profileToday('ward-1')]);
  });

  testWidgets('tapping a person who only sees me opens their card',
      (tester) async {
    final visited = await _pump(tester);

    await tester.tap(find.byKey(const ValueKey('relative-person-out-managed')));
    await tester.pumpAndSettle();

    expect(visited, [AppRoutes.relative('person-out-managed')]);
  });

  testWidgets('the pencil of a row opens the card', (tester) async {
    final visited = await _pump(tester);

    await tester.tap(find.byKey(const ValueKey('relative-edit-profile-in-1')));
    await tester.pumpAndSettle();

    expect(visited, [AppRoutes.relative('profile-in-1')]);
  });

  testWidgets('a note is shown before the name, the roles under it',
      (tester) async {
    await _pump(tester);

    final row = find.byKey(const ValueKey('relative-person-new'));
    expect(
      find.descendant(
        of: row,
        matching: find.text('Сын (Alex Relative Longname)'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: row, matching: find.text('observer')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('relative-ward-1')),
        matching: find.text('I manage'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a person related both ways is one row with both roles',
      (tester) async {
    await _pump(
      tester,
      overview: buildFamilyOverview(
        links: [
          familyLink(
            'in-1',
            direction: LinkDirection.incoming,
            counterpartProfileId: 'grace',
            role: 'editor',
          ),
          familyLink(
            'out-1',
            counterpart: 'Grace',
            counterpartProfileId: 'grace',
          ),
        ],
        profiles: const [],
      ),
    );

    final row = find.byKey(const ValueKey('relative-grace'));
    expect(row, findsOneWidget);
    expect(
      find.descendant(
        of: row,
        matching: find.text('ward · I can change, observer'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('every row is a card with a 48 avatar', (tester) async {
    await _pump(tester);

    for (final key in const [
      'relative-person-new',
      'relative-profile-in-1',
      'relative-ward-1',
      'relative-ward-2',
    ]) {
      final row = find.byKey(ValueKey(key));
      expect(
        find.ancestor(of: row, matching: find.byType(PillPalCard)),
        findsOneWidget,
        reason: '$key is in a card',
      );
      final avatar = find.descendant(
        of: row,
        matching: find.byKey(const Key('person-avatar')),
      );
      expect(avatar, findsOneWidget, reason: '$key has an avatar');
      expect(tester.getSize(avatar), const Size.square(PillPalSizes.avatarMd));
    }
  });

  testWidgets('the avatar holds the first letter of the name', (tester) async {
    await _pump(tester);

    final avatar = find.descendant(
      of: find.byKey(const ValueKey('relative-profile-in-1')),
      matching: find.byKey(const Key('person-avatar')),
    );
    expect(
      find.descendant(of: avatar, matching: find.text('G')),
      findsOneWidget,
    );
  });

  testWidgets('a paused link says so with an icon and a word', (tester) async {
    await _pump(tester);

    final pill = find.descendant(
      of: find.byKey(const ValueKey('relative-person-out-paused')),
      matching: find.byType(StatusPill),
    );
    expect(pill, findsOneWidget);
    expect(
      find.descendant(of: pill, matching: find.text('not active')),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: pill, matching: find.byIcon(Icons.pause_circle_outline)),
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
      find.descendant(of: invite, matching: find.text('Add')),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(invite).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const ValueKey('relative-ward-1'))).dy,
      ),
    );
  });

  testWidgets('one list: managed profiles, people I see, people who see me',
      (tester) async {
    await _pump(tester);

    double top(String key) =>
        tester.getTopLeft(find.byKey(ValueKey('relative-$key'))).dy;
    expect(top('ward-1'), lessThan(top('profile-in-1')));
    expect(top('profile-in-1'), lessThan(top('person-new')));
    expect(find.text('People I care for'), findsNothing);
  });

  testWidgets('at the relatives limit the button gives way to the notice',
      (tester) async {
    await _pump(
      tester,
      features: const AccountFeatures(
        softLimitsEnabled: true,
        relativesLimit: 2,
      ),
      overview: buildFamilyOverview(
        links: [familyLink('a'), familyLink('b')],
        profiles: const [],
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

    testWidgets('the invite action opens «Добавить близкого»', (tester) async {
      final visited = await _pump(
        tester,
        overview: familyNobody,
        pushHint: false,
      );

      await tester.tap(find.byKey(const Key('invite-self')));
      await tester.pumpAndSettle();

      expect(visited, [AppRoutes.addRelative]);
    });

    testWidgets('the accept entry is outlined like in the sections',
        (tester) async {
      await _pump(tester, overview: familyNobody, pushHint: false);

      expect(
        tester.widget(find.byKey(const Key('accept-invite'))),
        isA<OutlinedButton>(),
      );
    });

    testWidgets('pull to refresh asks for the links', (tester) async {
      final calls = <String>[];
      await _pump(
        tester,
        overview: familyNobody,
        pushHint: false,
        calls: calls,
      );
      calls.clear();

      await tester.drag(
        find.byKey(const Key('family-list')),
        // The trigger is a quarter of the viewport, which the test makes tall.
        const Offset(0, 2400),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      expect(calls, contains('refresh'));
    });

    testWidgets('a limit of 0 says why there is no invite', (tester) async {
      await _pump(
        tester,
        overview: familyNobody,
        pushHint: false,
        features: const AccountFeatures(
          softLimitsEnabled: true,
          relativesLimit: 0,
        ),
      );

      expect(find.byKey(const Key('relatives-limit')), findsOneWidget);
      expect(find.byKey(const Key('invite-self')), findsNothing);
    });

    testWidgets('the quiet entry is reachable at x2.0 on a short screen',
        (tester) async {
      await _pump(
        tester,
        overview: familyNobody,
        pushHint: false,
        textScale: 2,
      );
      tester.view.physicalSize = const Size(320, 568);
      await tester.pump();

      await tester.ensureVisible(find.byKey(const Key('accept-invite')));
      await tester.pumpAndSettle();

      final bottom =
          tester.getBottomLeft(find.byKey(const Key('accept-invite')));
      expect(bottom.dy, lessThanOrEqualTo(568));
    });
  });

  testWidgets('senior mode at OS x1.5 keeps the header and the invite',
      (tester) async {
    await _pump(tester, senior: true, textScale: 1.5);
    tester.view.physicalSize = const Size(360, 800);
    await tester.pump();

    expect(tester.takeException(), isNull);
    final title = tester.getRect(find.byKey(const Key('family-title')));
    final invite = tester.getRect(find.byKey(const Key('invite-self')));
    expect(invite.right, lessThanOrEqualTo(360));
    expect(title.right, lessThanOrEqualTo(360));
  });

  testWidgets('the row reads name, role and status as one button',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester);

    final node = tester.getSemantics(
      find
          .ancestor(
            of: find.byKey(const ValueKey('relative-person-out-paused')),
            matching: find.byType(MergeSemantics),
          )
          .first,
    );
    expect(node.getSemanticsData().label, contains('Robin'));
    expect(node.getSemanticsData().label, contains('observer'));
    expect(node.getSemanticsData().label, contains('not active'));
    semantics.dispose();
  });

  testWidgets('the row reads the note, the name and the roles', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester);

    final node = tester.getSemantics(
      find
          .ancestor(
            of: find.byKey(const ValueKey('relative-person-new')),
            matching: find.byType(MergeSemantics),
          )
          .first,
    );
    final label = node.getSemanticsData().label;
    expect(label, contains('Сын'));
    expect(label, contains('Alex Relative Longname'));
    expect(label, contains('observer'));
    semantics.dispose();
  });

  testWidgets('dismissing the new-relative banner marks the links seen',
      (tester) async {
    final calls = <String>[];
    await _pump(
      tester,
      fresh: [familyLink('new', counterpart: 'Alex')],
      calls: calls,
    );

    await tester.tap(find.byKey(const Key('new-relative-dismiss')));
    await tester.pump();

    expect(calls, contains('seen'));
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
