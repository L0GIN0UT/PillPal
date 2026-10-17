import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:pillpal/src/push/push_providers.dart';
import 'package:pillpal/src/push/push_service.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../helpers.dart';

class _FixedStatus extends PushStatusNotifier {
  _FixedStatus(this._status);

  final PushStatus _status;

  @override
  PushStatus build() => _status;
}

Future<void> _openFamily(WidgetTester tester, PushStatus status) async {
  final harness = TestHarness(
    handler: (request) async => http.Response('', 503),
  );
  final container = createContainer(
    harness,
    overrides: [
      pushStatusProvider.overrideWith(() => _FixedStatus(status)),
    ],
  );
  await harness.seedSelfProfile();
  await pumpApp(tester, harness: harness, container: container);
  goRoute(container, AppRoutes.family);
  await tester.pumpAndSettle();
}

void main() {
  const hint = Key('push-unavailable-hint');

  testWidgets('shown when alerts are needed but the phone has no provider',
      (tester) async {
    await _openFamily(
      tester,
      const PushStatus(PushAvailability.unavailable),
    );
    expect(find.byKey(hint), findsOneWidget);
    expect(find.textContaining('no push service'), findsOneWidget);
  });

  for (final availability in [
    PushAvailability.registered,
    PushAvailability.idle,
    PushAvailability.failed,
  ]) {
    testWidgets('not shown while ${availability.name}', (tester) async {
      await _openFamily(tester, PushStatus(availability));
      expect(find.byKey(hint), findsNothing);
    });
  }
}
