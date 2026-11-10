import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers.dart';
import 'family_fixtures.dart';

// The chips under the title of Today replace the old switcher: the same
// keys, the same choice, plus the «Все N» chip past four profiles.

void main() {
  testWidgets('one profile: no chips', (tester) async {
    final harness = TestHarness();
    await harness.seedSelfProfile();
    await pumpApp(tester, harness: harness);

    expect(find.byKey(const Key('profile-switcher')), findsNothing);
  });

  testWidgets('shows everyone and puts the chosen profile first',
      (tester) async {
    final harness = TestHarness();
    await harness.seedSelfProfile();
    await seedProfile(harness, id: 'ward-1', kind: 'managed', name: 'Pat');
    await seedProfile(harness, id: 'foreign-1', name: 'Grace');
    await pumpApp(tester, harness: harness);

    final me = find.byKey(const Key('profile-switch-$selfProfileId'));
    final pat = find.byKey(const Key('profile-switch-ward-1'));
    expect(me, findsOneWidget);
    expect(find.byKey(const Key('profile-switch-foreign-1')), findsOneWidget);
    expect(find.byKey(const Key('profile-chips-all')), findsNothing);
    expect(tester.getTopLeft(me).dx, lessThan(tester.getTopLeft(pat).dx));

    await tester.tap(pat);
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(pat).dx, lessThan(tester.getTopLeft(me).dx));
  });

  testWidgets('more than four profiles add the «All N» chip', (tester) async {
    final harness = TestHarness();
    await harness.seedSelfProfile();
    for (var i = 1; i <= 4; i++) {
      await seedProfile(harness, id: 'ward-$i', kind: 'managed', name: 'W$i');
    }
    await pumpApp(tester, harness: harness);

    expect(find.byKey(const Key('profile-chips-all')), findsOneWidget);
    expect(find.text('All 5'), findsOneWidget);
  });
}
