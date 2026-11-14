import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/src/features/catalog/scanner_adapter.dart';
import 'package:pillpal/src/features/family/invite_scan_sheet.dart';
import 'package:pillpal/src/links/link_providers.dart';
import 'package:pillpal/src/routing/routes.dart';

import '../features/fake_scanner.dart';
import '../helpers.dart';
import 'family_fixtures.dart';
import 'invite_server.dart';

// The invite scanner of «Добавить близкого» (docs/adr/0020): only our invite
// link counts (https, a link host of this region, the token in the
// fragment); the token goes to the invite intake and the accept screen only;
// the camera stops after the first valid code.

ScanBarcode _qr(String raw) => ScanBarcode(raw: raw, format: ScanFormat.qr);

class _Run {
  _Run(this.requests, this.scanners, this.container);

  final List<http.Request> requests;
  final List<FakeScannerAdapter> scanners;
  final ProviderContainer container;

  /// The camera of the sheet opened last.
  FakeScannerAdapter get scanner => scanners.last;
}

Future<_Run> _openScanner(WidgetTester tester) async {
  final requests = <http.Request>[];
  final harness = TestHarness(
    handler: (request) async {
      requests.add(request);
      if (request.url.path == '/v1/invites/preview') {
        return jsonResponse({
          'inviter_display_name': 'Grace Owner',
          'inviter_email_masked': 'g***@mail.ru',
          'profile_display_name': 'Grace',
          'profile_kind': 'self',
          'role': 'viewer',
          'expires_at': '2026-10-16T06:15:00Z',
        });
      }
      return http.Response('', 503);
    },
  );
  final scanners = <FakeScannerAdapter>[];
  final container = createContainer(
    harness,
    overrides: [
      // A new camera per sheet, as in the app: a closed sheet disposes it.
      inviteScannerFactoryProvider.overrideWithValue(() {
        final scanner = FakeScannerAdapter();
        scanners.add(scanner);
        return scanner;
      }),
    ],
  );
  await harness.seedSelfProfile();
  await pumpApp(tester, harness: harness, container: container);
  openRoute(container, AppRoutes.addRelative);
  await tester.pumpAndSettle();
  final scan = find.byKey(const Key('add-relative-scan'));
  await tester.ensureVisible(scan);
  await tester.tap(scan);
  await tester.pumpAndSettle();
  return _Run(requests, scanners, container);
}

Iterable<String> _paths(_Run run) =>
    run.requests.map((r) => '${r.method} ${r.url.path}');

void main() {
  for (final entry in {
    'another site': 'https://evil.example/i#$inviteToken',
    'plain http': 'http://links-ru.pillpal.invalid/i#$inviteToken',
    'another path': 'https://links-ru.pillpal.invalid/x#$inviteToken',
    'plain text': 'hello',
  }.entries) {
    testWidgets('${entry.key} is not a PillPal code', (tester) async {
      final run = await _openScanner(tester);

      run.scanner.show(_qr(entry.value));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('invite-scan-notice-notPillPal')),
        findsOneWidget,
      );
      expect(find.text('This is not a PillPal code'), findsOneWidget);
      // The sheet stays open and the camera keeps looking.
      expect(find.byKey(const Key('scan-viewfinder')), findsOneWidget);
      expect(run.scanner.paused, isFalse);
      expect(run.container.read(inviteIntakeProvider), isNull);
      expect(run.requests, isEmpty);
    });
  }

  testWidgets('a pack barcode is not a PillPal code either', (tester) async {
    final run = await _openScanner(tester);

    run.scanner.show(retailCode('04607000000014'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('invite-scan-notice-notPillPal')),
      findsOneWidget,
    );
    expect(run.requests, isEmpty);
  });

  testWidgets('a code of the other region says so', (tester) async {
    final run = await _openScanner(tester);

    run.scanner.show(_qr('https://links-eu.pillpal.invalid/i#$inviteToken'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('invite-scan-notice-otherRegion')),
      findsOneWidget,
    );
    expect(find.textContaining('another data region'), findsOneWidget);
    expect(run.requests, isEmpty);
  });

  testWidgets('a valid code opens the accept screen with the masked e-mail',
      (tester) async {
    final run = await _openScanner(tester);

    run.scanner.show(_qr(inviteUrl));
    await tester.pumpAndSettle();

    // The camera stops at the first valid code and the sheet is gone.
    expect(run.scanner.disposed, isTrue);
    expect(find.byKey(const Key('scan-viewfinder')), findsNothing);
    expect(
      find.text('Grace Owner is sharing their medications with you'),
      findsOneWidget,
    );
    // The masked e-mail on its own line, never joined with the name.
    expect(
      tester.widget<Text>(find.byKey(const Key('invite-preview-email'))).data,
      'Account: g***@mail.ru',
    );
    expect(find.byKey(const Key('invite-preview-caution')), findsOneWidget);
    expect(
      find.text('Accept only if someone you know showed you this code'),
      findsOneWidget,
    );
    // Previewed, not accepted; the token travels in the body only.
    expect(_paths(run), ['POST /v1/invites/preview']);
    final preview = run.requests.single;
    expect(jsonDecode(preview.body), {'token': inviteToken});
    expect(preview.url.toString(), isNot(contains(inviteToken)));
    // The intake handed the link over and forgot it.
    expect(run.container.read(inviteIntakeProvider), isNull);
  });

  testWidgets('the paste form of the accept screen scans too', (tester) async {
    final run = await _openScanner(tester);
    await tester.tap(find.byKey(const Key('invite-scan-paste')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('accept-link-field')), findsOneWidget);

    await tester.tap(find.byKey(const Key('accept-scan')));
    await tester.pumpAndSettle();
    run.scanner.show(_qr(inviteUrl));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('invite-preview-title')), findsOneWidget);
    expect(_paths(run), ['POST /v1/invites/preview']);
  });

  testWidgets('without the camera the person pastes a link instead',
      (tester) async {
    final run = await _openScanner(tester);

    run.scanner.fail(ScannerFailure.permissionDenied);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('invite-scan-notice-permission')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('scan-viewfinder')), findsNothing);

    await tester.tap(find.byKey(const Key('invite-scan-paste')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('accept-link-field')), findsOneWidget);
    expect(run.requests, isEmpty);
  });
}
