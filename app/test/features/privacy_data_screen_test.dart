import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../helpers.dart';
import '../support/consent_server.dart';
import '../support/privacy_server.dart';

// «Приватность и данные» (board B2-SettingsData, ADR 0016 §4 and §8): the
// consents with date and version, the health switch that opens the account
// deletion instead of withdrawing, the withdrawal of the catalog contribution,
// and when the export row shows.

Future<void> _tap(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

/// Settings -> «Privacy and data».
Future<(ProviderContainer, TestHarness)> _open(
  WidgetTester tester,
  FakePrivacyServer server,
) async {
  final harness = TestHarness(handler: server.handle);
  final container = createContainer(harness);
  await container.read(syncStateStoreProvider).bindAccount('user-1', 'ru');
  await pumpApp(tester, harness: harness, container: container);
  openRoute(container, AppRoutes.settings);
  await tester.pumpAndSettle();
  await _tap(tester, 'settings-privacy-data');
  return (container, harness);
}

FakePrivacyServer _server({
  List<Map<String, Object?>>? records,
  bool exportEnabled = true,
  bool hasPassword = true,
}) {
  return FakePrivacyServer()
    ..exportEnabled = exportEnabled
    ..hasPassword = hasPassword
    ..consents.records = records ??
        [
          consentRecord('health_data'),
          consentRecord('terms'),
          consentRecord('privacy'),
        ];
}

String _text(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

void main() {
  testWidgets('the settings row opens the screen', (tester) async {
    await _open(tester, _server());

    expect(find.byKey(const Key('privacy-consents-header')), findsOneWidget);
    expect(find.text('Privacy and data'), findsWidgets);
  });

  group('the consents', () {
    testWidgets('each one shows its date and version', (tester) async {
      await _open(tester, _server());

      expect(
        _text(tester, 'privacy-health-text'),
        startsWith('Given on Oct 1, 2026, version 1'),
      );
      expect(find.text('Given on Oct 1, 2026, version 1'), findsNWidgets(2));
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('privacy-health')))
            .value,
        isTrue,
      );
    });

    testWidgets('a withdrawn or missing record is "Not given"', (tester) async {
      await _open(
        tester,
        _server(
          records: [
            consentRecord('health_data', withdrawn: true),
            consentRecord('terms'),
          ],
        ),
      );

      expect(
        _text(tester, 'privacy-health-text'),
        startsWith('Not given'),
      );
      expect(find.text('Not given'), findsOneWidget, reason: 'privacy policy');
      expect(
        tester
            .widget<SwitchListTile>(find.byKey(const Key('privacy-health')))
            .value,
        isFalse,
      );
    });

    testWidgets('the newest active record of a kind decides', (tester) async {
      final older = consentRecord('terms');
      final newer = {
        ...consentRecord('terms', version: 2),
        'accepted_at': '2026-10-20T09:00:00Z',
      };
      await _open(tester, _server(records: [older, newer]));

      expect(find.text('Given on Oct 20, 2026, version 2'), findsOneWidget);
    });

    testWidgets('a load failure offers to try again', (tester) async {
      final server = _server()..consents.getOffline = true;
      await _open(tester, server);

      expect(find.byKey(const Key('privacy-load-failed')), findsOneWidget);
      expect(find.byKey(const Key('privacy-health')), findsNothing);

      server.consents.getOffline = false;
      await _tap(tester, 'privacy-retry');

      expect(find.byKey(const Key('privacy-health')), findsOneWidget);
    });
  });

  group('the health data switch', () {
    testWidgets('opens the deletion dialog with a lead and withdraws nothing',
        (tester) async {
      final server = _server();
      await _open(tester, server);

      await _tap(tester, 'privacy-health');

      expect(find.byKey(const Key('delete-account-confirm')), findsOneWidget);
      expect(find.textContaining('withdrawn by deleting your account'),
          findsOneWidget);
      expect(find.textContaining('erased no later than'), findsOneWidget);
      expect(server.calls, isNot(contains('POST /v1/me/consents/withdraw')));
      expect(server.calls.where((call) => call.startsWith('DELETE')), isEmpty);

      await _tap(tester, 'delete-account-cancel');
      expect(find.byKey(const Key('delete-account-confirm')), findsNothing);
    });
  });

  group('the catalog contribution', () {
    testWidgets('is listed only while a record of it is active',
        (tester) async {
      await _open(tester, _server());
      expect(find.byKey(const Key('privacy-contribution')), findsNothing);
    });

    testWidgets('a withdrawn one is not listed', (tester) async {
      await _open(
        tester,
        _server(
          records: [
            consentRecord('health_data'),
            consentRecord('catalog_contribution', withdrawn: true),
          ],
        ),
      );
      expect(find.byKey(const Key('privacy-contribution')), findsNothing);
    });

    testWidgets(
        'withdrawing asks, posts the kind, tells how many links '
        'were reset and asks for a sync', (tester) async {
      final server = _server(
        records: [
          consentRecord('health_data'),
          consentRecord('catalog_contribution'),
        ],
      );
      final (_, harness) = await _open(tester, server);
      expect(find.byKey(const Key('privacy-contribution')), findsOneWidget);

      await _tap(tester, 'privacy-contribution-withdraw');
      expect(server.withdrawn, isEmpty, reason: 'it asks first');
      await _tap(tester, 'confirm-yes');

      expect(server.withdrawn, ['catalog_contribution']);
      expect(find.text('Consent withdrawn. 2 links reset.'), findsOneWidget);
      expect(find.byKey(const Key('privacy-contribution')), findsNothing);
      expect(harness.syncCalls, greaterThanOrEqualTo(1));
    });

    testWidgets('cancelling the question withdraws nothing', (tester) async {
      final server = _server(
        records: [
          consentRecord('health_data'),
          consentRecord('catalog_contribution'),
        ],
      );
      await _open(tester, server);

      await _tap(tester, 'privacy-contribution-withdraw');
      await _tap(tester, 'confirm-no');

      expect(server.withdrawn, isEmpty);
      expect(find.byKey(const Key('privacy-contribution')), findsOneWidget);
    });

    testWidgets('a refusal is a snack bar and the row stays', (tester) async {
      final server = _server(
        records: [
          consentRecord('health_data'),
          consentRecord('catalog_contribution'),
        ],
      )..withdrawFailure = (500, 'internal_error');
      await _open(tester, server);

      await _tap(tester, 'privacy-contribution-withdraw');
      await _tap(tester, 'confirm-yes');

      expect(
          find.text('Something went wrong. Please try again.'), findsOneWidget);
      expect(find.byKey(const Key('privacy-contribution')), findsOneWidget);
    });
  });

  group('the export row', () {
    testWidgets('shows when the server has the export on', (tester) async {
      await _open(tester, _server());

      expect(find.byKey(const Key('privacy-export')), findsOneWidget);
      expect(
        find.text(
          'A JSON archive, can be downloaded once within 24 hours',
        ),
        findsOneWidget,
      );
    });

    testWidgets('is hidden while the flag is off', (tester) async {
      await _open(tester, _server(exportEnabled: false));

      expect(find.byKey(const Key('privacy-export')), findsNothing);
    });

    testWidgets('is hidden for an account without a password', (tester) async {
      await _open(tester, _server(hasPassword: false));

      expect(find.byKey(const Key('privacy-export')), findsNothing);
    });

    testWidgets('opens the export screen', (tester) async {
      await _open(tester, _server());

      await _tap(tester, 'privacy-export');

      expect(find.byKey(const Key('export-submit')), findsOneWidget);
    });
  });
}
