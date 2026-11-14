import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/repositories/relatives_repository.dart';
import 'package:pillpal/src/features/common/choice_button.dart';
import 'package:pillpal/src/features/common/local_time.dart';
import 'package:pillpal/src/features/family/archived_profile_banner.dart';
import 'package:pillpal/src/features/family/family_providers.dart';
import 'package:pillpal/src/features/family/family_tiles.dart';
import 'package:pillpal/src/features/family/new_relative_banner.dart';
import 'package:pillpal/src/features/family/profile_context.dart';
import 'package:pillpal/src/features/family/profile_switcher.dart';
import 'package:pillpal/src/features/family/relatives_list.dart';
import 'package:pillpal/src/localization_delegates.dart';
import 'package:pillpal/src/theme/app_theme.dart';

// The callbacks and selection of the Family widgets, on their own.

ProfileRow _profile(String id, String kind, String name) => ProfileRow(
      id: id,
      kind: kind,
      displayName: name,
      timezone: 'Europe/Berlin',
      clientUpdatedAt: 1,
      updatedByDevice: 'test-device',
      missedAlertMinutes: 30,
      missedAlertsEnabled: true,
    );

final _own = ProfileAccess(
  profile: _profile('self-1', 'self', 'Test User'),
  role: 'owner',
);
final _ward = ProfileAccess(
  profile: _profile('ward-1', 'managed', 'Pat Ward'),
  role: 'owner',
);

RelativeLinkRow _link(String id) => RelativeLinkRow(
      id: id,
      direction: LinkDirection.incoming,
      profileId: 'foreign-1',
      role: 'viewer',
      counterpartName: 'Alex Relative',
      active: true,
      notifyMissed: true,
      createdAt: DateTime.utc(2026, 10, 10).microsecondsSinceEpoch,
      profileName: 'Grace',
      profileKind: 'self',
    );

Widget _host(Widget child, {List<Override> overrides = const []}) {
  return ProviderScope(
    overrides: [
      deviceTimeZoneProvider.overrideWithValue('Europe/Berlin'),
      ...overrides,
    ],
    child: MaterialApp(
      theme: buildPillPalTheme(brightness: Brightness.light, senior: false),
      localizationsDelegates: pillPalLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
}

class _Selected extends SelectedProfile {
  _Selected(this.initial, this.chosen);

  final String? initial;
  final List<String?> chosen;

  @override
  String? build() => initial;

  @override
  void select(String? profileId) => chosen.add(profileId);
}

class _Actions extends FamilyActions {
  _Actions(super.ref, this.log);

  final List<String> log;

  @override
  Future<void> markSeen() async => log.add('seen');
}

void main() {
  group('ProfileSwitcher', () {
    Future<List<bool>> pumpSwitcher(
      WidgetTester tester,
      String? selected,
      List<String?> chosen,
    ) async {
      await tester.pumpWidget(
        _host(
          const ProfileSwitcher(),
          overrides: [
            accessibleProfilesProvider
                .overrideWith((ref) => Stream.value([_own, _ward])),
            selectedProfileIdProvider
                .overrideWith(() => _Selected(selected, chosen)),
          ],
        ),
      );
      await tester.pump();
      return [
        for (final id in ['self-1', 'ward-1'])
          tester
              .widget<ChoiceButton>(find.byKey(ValueKey('profile-switch-$id')))
              .selected,
      ];
    }

    testWidgets('null selection highlights the own profile', (tester) async {
      expect(await pumpSwitcher(tester, null, []), [true, false]);
    });

    testWidgets('the own id highlights the own profile', (tester) async {
      expect(await pumpSwitcher(tester, 'self-1', []), [true, false]);
    });

    testWidgets('another profile highlights only itself', (tester) async {
      expect(await pumpSwitcher(tester, 'ward-1', []), [false, true]);
    });

    testWidgets('an unknown id highlights nothing', (tester) async {
      expect(await pumpSwitcher(tester, 'gone', []), [false, false]);
    });

    testWidgets('tapping the own profile writes null, another its id',
        (tester) async {
      final chosen = <String?>[];
      await pumpSwitcher(tester, 'ward-1', chosen);

      await tester.tap(find.byKey(const ValueKey('profile-switch-self-1')));
      await tester.tap(find.byKey(const ValueKey('profile-switch-ward-1')));

      expect(chosen, [null, 'ward-1']);
    });
  });

  testWidgets('the tile actions call their own callbacks', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      _host(
        Column(
          children: [
            for (final relative in buildRelatives(
              links: [_link('in-1')],
              profiles: [_ward],
            ))
              RelativeTile(
                relative: relative,
                onOpen: () => calls.add('open-${relative.key}'),
                onEdit: () => calls.add('edit-${relative.key}'),
              ),
          ],
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('relative-edit-foreign-1')));
    await tester.tap(find.byKey(const ValueKey('relative-edit-ward-1')));
    await tester.tap(find.byKey(const ValueKey('relative-foreign-1')));
    await tester.tap(find.byKey(const ValueKey('relative-ward-1')));

    expect(calls, [
      'edit-foreign-1',
      'edit-ward-1',
      'open-foreign-1',
      'open-ward-1',
    ]);
  });

  testWidgets('the archive banner asks before leaving', (tester) async {
    final archive = ProfileAccess(
      profile: _profile('ward-2', 'managed', 'Sam Archive'),
      role: 'guardian',
      archived: true,
    );
    await tester.pumpWidget(_host(ArchivedProfileBanner(access: archive)));

    await tester.tap(find.byKey(const Key('archive-leave')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('confirm-yes')), findsOneWidget);
    expect(find.byKey(const Key('archive-purge')), findsNothing);
  });

  testWidgets('dismissing the new-relative banner marks the links seen',
      (tester) async {
    final log = <String>[];
    await tester.pumpWidget(
      _host(
        const NewRelativeBanner(),
        overrides: [
          newRelativesProvider.overrideWithValue([_link('new')]),
          familyActionsProvider.overrideWith((ref) => _Actions(ref, log)),
        ],
      ),
    );

    await tester.tap(find.byKey(const Key('new-relative-dismiss')));

    expect(log, ['seen']);
  });
}
