import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';

import '../helpers.dart';

// Step 2 of 3 of the registration (docs/design/b2/B2-Consent, ADR 0016 §3).

const _boxes = ['consent-terms', 'consent-privacy', 'consent-health'];

http.Response _error(int status, String code) => http.Response(
      jsonEncode({
        'error': {'code': code, 'message': 'synthetic'},
      }),
      status,
      headers: {'content-type': 'application/json'},
    );

AppLocalizations get _en => lookupAppLocalizations(const Locale('en'));

/// Opens the consent step: welcome, then valid credentials.
Future<List<http.Request>> _openConsent(
  WidgetTester tester, {
  Future<http.Response> Function(http.Request)? answer,
}) async {
  final requests = <http.Request>[];
  final harness = TestHarness(
    signedIn: false,
    handler: (request) async {
      requests.add(request);
      return answer == null ? http.Response('', 202) : answer(request);
    },
  );
  await pumpApp(tester, harness: harness);
  await tester.tap(find.byKey(const Key('welcome-register')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('auth-name')), 'Test User');
  await tester.enterText(
    find.byKey(const Key('auth-email')),
    'user@example.test',
  );
  await tester.enterText(
    find.byKey(const Key('auth-password')),
    'long-enough-password',
  );
  await tester.tap(find.byKey(const Key('auth-submit')));
  await tester.pumpAndSettle();
  return requests;
}

Future<void> _tick(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.tap(find.byKey(Key(key)));
  await tester.pump();
}

bool _ticked(WidgetTester tester, String key) =>
    tester.widget<CheckboxListTile>(find.byKey(Key(key))).value ?? false;

bool _submitEnabled(WidgetTester tester) {
  final button = find.descendant(
    of: find.byKey(const Key('consent-submit')),
    matching: find.byType(FilledButton),
  );
  return tester.widget<FilledButton>(button).onPressed != null;
}

void main() {
  testWidgets('the step is 2 of 3 and nothing is ticked beforehand', (
    tester,
  ) async {
    await _openConsent(tester);

    expect(find.text(_en.stepOf(2, 3)), findsOneWidget);
    for (final key in _boxes) {
      expect(_ticked(tester, key), isFalse, reason: key);
    }
    expect(_submitEnabled(tester), isFalse);
    expect(find.byKey(const Key('consent-hint')), findsOneWidget);
  });

  testWidgets('the button waits for all three boxes, which are independent', (
    tester,
  ) async {
    final requests = await _openConsent(tester);

    await _tick(tester, 'consent-terms');
    expect(_ticked(tester, 'consent-terms'), isTrue);
    expect(_ticked(tester, 'consent-privacy'), isFalse);
    expect(_ticked(tester, 'consent-health'), isFalse);
    await _tick(tester, 'consent-privacy');
    expect(_submitEnabled(tester), isFalse);

    // Health data alone does not stand for the other two, and the reverse.
    await _tick(tester, 'consent-health');
    expect(_submitEnabled(tester), isTrue);
    expect(find.byKey(const Key('consent-hint')), findsNothing);

    await _tick(tester, 'consent-terms');
    expect(_ticked(tester, 'consent-terms'), isFalse);
    expect(_ticked(tester, 'consent-health'), isTrue);
    expect(_submitEnabled(tester), isFalse);
    expect(requests, isEmpty);
  });

  testWidgets('the disabled button says why, as text and as a hint',
      (tester) async {
    final handle = tester.ensureSemantics();
    await _openConsent(tester);

    expect(find.text(_en.consentSubmitHint), findsOneWidget);
    expect(
      tester.getSemantics(find.byKey(const Key('consent-submit'))).hint,
      contains(_en.consentSubmitHint),
    );
    final before = tester.getRect(find.byKey(const Key('consent-submit')));
    for (final key in _boxes) {
      await _tick(tester, key);
    }
    // The reason's space stays: the button does not jump.
    expect(
      tester.getRect(find.byKey(const Key('consent-submit'))),
      before,
    );
    expect(find.byKey(const Key('consent-hint')), findsNothing);
    handle.dispose();
  });

  testWidgets('health data is a card of its own with its version line', (
    tester,
  ) async {
    await _openConsent(tester);

    final card = find.byKey(const Key('consent-health-card'));
    expect(card, findsOneWidget);
    expect(
      find.descendant(
        of: card,
        matching: find.byKey(const Key('consent-health')),
      ),
      findsOneWidget,
    );
    for (final key in ['consent-terms', 'consent-privacy']) {
      expect(
        find.descendant(of: card, matching: find.byKey(Key(key))),
        findsNothing,
        reason: key,
      );
    }
    expect(find.text(_en.consentHealthBody), findsOneWidget);
    // The number, not only the date: the record names the version.
    expect(find.text('Version 1 of Nov 1, 2026'), findsOneWidget);
    expect(
      find.text(_en.consentVersionLine(1, 'Nov 1, 2026')),
      findsOneWidget,
    );
  });

  testWidgets('the links open the full texts in a sheet', (tester) async {
    await _openConsent(tester);
    final texts = {
      'consent-text-terms': _en.consentTextBodyTerms,
      'consent-text-privacy': _en.consentTextBodyPrivacy,
      'consent-text-health': _en.consentTextBodyHealth,
    };
    for (final entry in texts.entries) {
      await tester.ensureVisible(find.byKey(Key(entry.key)));
      await tester.tap(find.byKey(Key(entry.key)));
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget, reason: entry.key);
      expect(
        find.text('Version 1 of Nov 1, 2026'),
        findsWidgets,
        reason: entry.key,
      );
      await tester.tap(find.byKey(const Key('consent-text-close')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('consent-text-body')), findsNothing);
    }
    // Reading is not accepting.
    for (final key in _boxes) {
      expect(_ticked(tester, key), isFalse, reason: key);
    }
  });

  testWidgets('a refused consent version is shown in the banner', (
    tester,
  ) async {
    await _openConsent(
      tester,
      answer: (request) async => _error(422, 'unsupported_consent_version'),
    );
    for (final key in _boxes) {
      await _tick(tester, key);
    }
    await tester.tap(find.byKey(const Key('consent-submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('auth-error')), findsOneWidget);
    expect(find.text(_en.errorConsentOutdated), findsOneWidget);
    expect(find.byKey(const Key('consent-submit')), findsOneWidget);
    expect(find.byKey(const Key('auth-code')), findsNothing);
  });

  testWidgets('success leads to the code step, the third of three', (
    tester,
  ) async {
    final requests = await _openConsent(tester);
    for (final key in _boxes) {
      await _tick(tester, key);
    }
    await tester.tap(find.byKey(const Key('consent-submit')));
    await tester.pumpAndSettle();

    expect(
      requests.where((r) => r.url.path == '/v1/auth/register'),
      hasLength(1),
    );
    expect(find.byKey(const Key('auth-code')), findsOneWidget);
    expect(find.text(_en.stepOf(3, 3)), findsOneWidget);
    expect(find.byKey(const Key('consent-submit')), findsNothing);
  });

  testWidgets('a sign-in that needs a code shows no registration step', (
    tester,
  ) async {
    await pumpApp(
      tester,
      harness: TestHarness(
        signedIn: false,
        handler: (request) async => request.url.path == '/v1/auth/login'
            ? _error(403, 'email_not_verified')
            : http.Response('', 202),
      ),
    );
    await tester.tap(find.byKey(const Key('welcome-login')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('auth-email')),
      'user@example.test',
    );
    await tester.enterText(
      find.byKey(const Key('auth-password')),
      'some-password',
    );
    await tester.tap(find.byKey(const Key('auth-submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('auth-code')), findsOneWidget);
    for (var n = 1; n <= 3; n++) {
      expect(find.text(_en.stepOf(n, 3)), findsNothing);
    }
  });
}
