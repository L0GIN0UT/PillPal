import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/routing/routes.dart';
import 'package:pillpal/src/settings/app_settings.dart';
import 'package:pillpal/src/theme/app_theme.dart';

import '../helpers.dart';
import 'family_fixtures.dart';

// Senior mode scales text by PillPalSizes.seniorTextScale on top of the
// system scale: a relative's long name must wrap, not overflow the header.

void main() {
  testWidgets('a long name wraps in the header at text scale 2.0',
      (tester) async {
    // The senior factor and the system factor multiply: 2.0 in total.
    tester.platformDispatcher.textScaleFactorTestValue =
        2.0 / PillPalSizes.seniorTextScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final harness = TestHarness();
    final container = createContainer(harness);
    await harness.seedSelfProfile();
    final profile = await seedProfile(
      harness,
      role: 'editor',
      name: 'Alexandra Maximilienne Montgomery-Fitzgerald Wellington',
    );
    await pumpApp(tester, harness: harness, container: container);
    container.read(settingsProvider.notifier).setSeniorMode(enabled: true);
    await tester.pumpAndSettle();

    openRoute(container, AppRoutes.profileToday(profile));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final title = find.byKey(const Key('today-title'));
    expect(title, findsOneWidget);
    expect(find.byKey(const Key('day-back')), findsOneWidget);
    expect(find.byKey(const Key('today-add')), findsOneWidget);
    // The name takes the space between the buttons, wrapped over lines.
    final view = tester.view;
    final width = view.physicalSize.width / view.devicePixelRatio;
    expect(tester.getSize(title).width, lessThan(width));
  });
}
