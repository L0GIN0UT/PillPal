import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/data/api/account_dto.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/features/auth/auth_flow.dart';
import 'package:pillpal/src/features/auth/auth_widgets.dart';
import 'package:pillpal/src/features/auth/auth_session.dart';
import 'package:pillpal/src/features/auth/credentials_screens.dart';
import 'package:pillpal/src/features/auth/registration_consent_screen.dart';
import 'package:pillpal/src/features/auth/restore_screen.dart';
import 'package:pillpal/src/features/auth/verify_screen.dart';
import 'package:pillpal/src/features/auth/welcome_screen.dart';
import 'package:pillpal/src/features/common/local_time.dart';
import 'package:pillpal/src/features/shell/empty_state.dart';

import '../support/ui_matrix.dart';

// The onboarding screens in the whole UI matrix (docs/ui-pass-plan.md, UI-4):
// light/dark, normal/senior, RU/EN, text scale 1 and 2, two screen sizes.

/// Auth flow whose state is fixed by the test.
class _FixedFlow extends AuthFlowController {
  _FixedFlow(this.initial);

  final AuthFlowState initial;

  @override
  AuthFlowState build() => initial;
}

Widget _screen(
  Widget screen, {
  AuthFlowState flow = const AuthFlowState(),
  bool localData = true,
}) {
  return ProviderScope(
    overrides: [
      authFlowProvider.overrideWith(() => _FixedFlow(flow)),
      hasBoundLocalDataProvider.overrideWith((ref) async => localData),
      deviceTimeZoneProvider.overrideWithValue('Europe/Moscow'),
      // The build serves RU; an English device suggests EU.
      apiConfigProvider.overrideWithValue(
        ApiConfig(baseUrl: Uri.parse('https://api.example.test'), region: 'ru'),
      ),
    ],
    // The matrix places the widget at the top start with loose constraints.
    child: SizedBox(
      width: double.infinity,
      height: double.infinity,
      child: screen,
    ),
  );
}

/// Height that holds a whole screen at the largest text scale of the matrix.
const double _tallScreen = 20000;

/// A list builds only what is near the viewport: make the screen tall so
/// every key of the screen is built, then look for it.
Future<void> _buildAll(WidgetTester tester, UiMatrixCase cell) async {
  tester.view.physicalSize = Size(cell.size.width, _tallScreen);
  await tester.pump();
}

UiMatrixCheck _expectKeys(List<String> keys) {
  return (tester, cell) async {
    // The local-data notices arrive after the first frame.
    await tester.pump();
    await _buildAll(tester, cell);
    expectTouchTargetsOf(tester, cell);
    for (final key in keys) {
      expect(
        find.byKey(Key(key)),
        findsOneWidget,
        reason: '"$key" is missing in "${cell.label}"',
      );
    }
  };
}

/// Scrolls the screen's list until [target] is built and on screen.
Future<void> _scrollTo(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    100,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
}

/// The primary action is fully on screen with the keyboard closed, however
/// large the text (B2-README section 9.6): it sits below the scrolling part.
void _expectPinnedAction(
  WidgetTester tester,
  UiMatrixCase cell,
  String key, {
  String screenName = '',
}) {
  final rect = tester.getRect(find.byKey(Key(key)));
  final screen = Offset.zero & cell.size;
  expect(
    screen.contains(rect.topLeft) && screen.contains(rect.bottomRight),
    isTrue,
    reason: '"$key" of $screenName is off screen in "${cell.label}": $rect',
  );
}

void main() {
  const failed = AuthFlowState(errorCode: 'invalid_credentials');

  testWidgets('Welcome in the matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(const WelcomeScreen()),
      expectTouchTargets: true,
      check: (tester, cell) async {
        await tester.pump();
        expectTouchTargetsOf(tester, cell);
        await _buildAll(tester, cell);
        expectTouchTargetsOf(tester, cell);
        // Q5: no region card, choice or other-region note until A4.
        for (final key in [
          'region-build',
          'region-other-later',
          'data-location',
        ]) {
          expect(
            find.byKey(Key(key)),
            findsNothing,
            reason: '"$key" is back in "${cell.label}"',
          );
        }
        for (final key in [
          'welcome-register',
          'welcome-login',
          'session-ended',
        ]) {
          expect(
            find.byKey(Key(key)),
            findsOneWidget,
            reason: '"$key" is missing in "${cell.label}"',
          );
        }
      },
    );
  });

  testWidgets('Register in the matrix with an error and a warning',
      (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(const RegisterScreen(), flow: failed),
      expectTouchTargets: true,
      check: _expectKeys([
        'auth-email',
        'auth-password',
        'auth-submit',
        'auth-error',
        'other-account-warning',
      ]),
    );
  });

  testWidgets('Login in the matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(const LoginScreen(), localData: false),
      expectTouchTargets: true,
      check: _expectKeys([
        'auth-email',
        'auth-password',
        'auth-forgot',
        'auth-submit',
      ]),
    );
  });

  testWidgets('Consent in the matrix with an error', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(
        const RegistrationConsentScreen(),
        flow: const AuthFlowState(
          email: 'user@example.test',
          registering: true,
          credentialsHeld: true,
          errorCode: 'consent_outdated',
        ),
        localData: false,
      ),
      expectTouchTargets: true,
      check: _expectKeys([
        'consent-terms',
        'consent-privacy',
        'consent-health',
        'consent-health-card',
        'consent-health-version',
        'consent-text-terms',
        'consent-text-privacy',
        'consent-text-health',
        'consent-hint',
        'consent-submit',
        'auth-error',
      ]),
    );
  });

  testWidgets('Verify in the matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(
        const VerifyScreen(),
        flow: const AuthFlowState(
          email: 'user@example.test',
          registering: true,
          errorCode: 'invalid_code',
        ),
      ),
      expectTouchTargets: true,
      check: _expectKeys(['auth-code', 'auth-submit', 'auth-error']),
    );
  });

  testWidgets('Restore in the matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(
        const RestoreScreen(),
        flow: AuthFlowState(
          email: 'user@example.test',
          errorCode: 'invalid_token',
          restore: PendingDeletion(
            restoreTicket: 'ticket',
            eraseAfter: DateTime.utc(2030, 1, 20),
          ),
        ),
      ),
      expectTouchTargets: true,
      check: _expectKeys(['restore-code', 'restore-submit', 'auth-error']),
    );
  });

  testWidgets('Restore without a ticket in the matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(const RestoreScreen()),
      expectTouchTargets: true,
      check: _expectKeys(['restore-lost', 'restore-back']),
    );
  });

  // Contrast is read from pixels, so the whole text must be on screen: the
  // scrolling part is shorter than its content in senior mode, and a text that
  // is scrolled under the pinned buttons would be measured against them. Each
  // screen is checked in its plain state; banners have their own contrast test.
  testWidgets('the onboarding screens meet the contrast of the mode',
      (tester) async {
    final plain = <String, Widget>{
      'welcome': const WelcomeScreen(),
      'register': const RegisterScreen(),
      'consent': const RegistrationConsentScreen(),
      'login': const LoginScreen(),
      'verify': const VerifyScreen(),
      'restore lost': const RestoreScreen(),
    };
    for (final entry in plain.entries) {
      try {
        await pumpUiMatrix(
          tester,
          (context) => _screen(entry.value, localData: false),
          expectContrast: true,
          scales: const [1.0],
          sizes: const [Size(360, 800)],
        );
      } on TestFailure catch (e) {
        fail('contrast of the ${entry.key} screen: ${e.message}');
      }
    }
    await pumpUiMatrix(
      tester,
      (context) => _screen(
        const RestoreScreen(),
        flow: AuthFlowState(
          email: 'user@example.test',
          restore: PendingDeletion(
            restoreTicket: 'ticket',
            eraseAfter: DateTime.utc(2030, 1, 20),
          ),
        ),
        localData: false,
      ),
      expectContrast: true,
      scales: const [1.0],
      sizes: const [Size(360, 800)],
    );
  });

  testWidgets('every state of every screen is readable at x2.0',
      (tester) async {
    // The view is made tall so no text is scrolled under the pinned buttons
    // (the pixel guideline would measure it against them); banners and the
    // step line are on screen.
    final states = <String, (Widget, AuthFlowState)>{
      'register': (const RegisterScreen(), failed),
      'consent': (
        const RegistrationConsentScreen(),
        const AuthFlowState(
          credentialsHeld: true,
          errorCode: 'consent_outdated',
        ),
      ),
      'login': (const LoginScreen(), failed),
      'verify': (
        const VerifyScreen(),
        const AuthFlowState(
          email: 'user@example.test',
          errorCode: 'invalid_code',
        ),
      ),
      'restore': (
        const RestoreScreen(),
        AuthFlowState(
          email: 'user@example.test',
          errorCode: 'invalid_token',
          restore: PendingDeletion(
            restoreTicket: 'ticket',
            eraseAfter: DateTime.utc(2030, 1, 20),
          ),
        ),
      ),
      'restore lost': (const RestoreScreen(), const AuthFlowState()),
      'welcome': (const WelcomeScreen(), const AuthFlowState()),
    };
    for (final entry in states.entries) {
      final (screen, flow) = entry.value;
      await pumpUiMatrix(
        tester,
        (context) => _screen(screen, flow: flow),
        scales: const [2.0],
        sizes: const [Size(320, 568)],
        check: (tester, cell) async {
          tester.view.physicalSize = Size(cell.size.width, _tallScreen / 5);
          await tester.pump();
          try {
            await expectContrastOf(tester, cell);
          } on TestFailure catch (e) {
            fail('contrast of the ${entry.key} screen: ${e.message}');
          }
        },
      );
    }
  });

  testWidgets('the focused field stays visible with the keyboard open',
      (tester) async {
    const keyboard = 260.0;
    final screens = <String, (Widget, String)>{
      'register': (const RegisterScreen(), 'auth-password'),
      'login': (const LoginScreen(), 'auth-password'),
      'verify': (const VerifyScreen(), 'auth-code'),
    };
    for (final entry in screens.entries) {
      final (screen, key) = entry.value;
      await pumpUiMatrix(
        tester,
        (context) => _screen(screen, flow: failed, localData: false),
        scales: const [2.0],
        sizes: const [Size(320, 568), Size(360, 640)],
        check: (tester, cell) async {
          tester.view.viewInsets = const FakeViewPadding(bottom: keyboard);
          addTearDown(tester.view.resetViewInsets);
          await tester.pump();
          final field = find.byKey(Key(key));
          await _scrollTo(tester, field);
          await tester.tap(field);
          await tester.pump();
          await tester.pump();
          final rect = tester.getRect(field);
          expect(
            rect.top >= 0 && rect.bottom <= cell.size.height - keyboard,
            isTrue,
            reason: '${entry.key} "$key" hidden by the keyboard in '
                '"${cell.label}": $rect',
          );
          tester.view.resetViewInsets();
        },
      );
    }
  });

  testWidgets('a long label and helper are not clipped on the narrowest screen',
      (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(const RegisterScreen(), localData: false),
      scales: const [2.0],
      sizes: const [Size(320, 568)],
      check: (tester, cell) async {
        await _scrollTo(tester, find.byKey(const Key('auth-password')));
        final l10n = lookupAppLocalizations(cell.locale);
        final helper = find.text(l10n.passwordHint(AuthLimits.passwordMin));
        expect(helper, findsOneWidget);
        final box = tester.getRect(helper);
        expect(
          box.left >= 0 && box.right <= cell.size.width,
          isTrue,
          reason: 'helper leaves the screen in "${cell.label}": $box',
        );
      },
    );
  });

  testWidgets('Register shows no region line and no region choice',
      (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(const RegisterScreen(), localData: false),
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async {
        final l10n = lookupAppLocalizations(cell.locale);
        expect(find.byKey(const Key('data-location')), findsNothing);
        expect(find.text(l10n.regionRuHint), findsNothing);
        expect(find.text(l10n.regionEuHint), findsNothing);
        expect(find.byType(Radio), findsNothing);
      },
    );
  });

  testWidgets('Register shows the step indicator and pins its action',
      (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(const RegisterScreen()),
      check: (tester, cell) async {
        final l10n = lookupAppLocalizations(cell.locale);
        expect(
          find.text(l10n.stepOf(1, 3)),
          findsOneWidget,
          reason: 'step indicator in "${cell.label}"',
        );
        _expectPinnedAction(tester, cell, 'auth-submit');
      },
    );
  });

  testWidgets('Login, Verify and Restore pin their action', (tester) async {
    final screens = <String, (Widget, AuthFlowState, String)>{
      'login': (const LoginScreen(), const AuthFlowState(), 'auth-submit'),
      'consent': (
        const RegistrationConsentScreen(),
        const AuthFlowState(credentialsHeld: true),
        'consent-submit',
      ),
      'verify': (
        const VerifyScreen(),
        const AuthFlowState(email: 'user@example.test'),
        'auth-submit',
      ),
      'restore': (
        const RestoreScreen(),
        AuthFlowState(
          email: 'user@example.test',
          restore: PendingDeletion(
            restoreTicket: 'ticket',
            eraseAfter: DateTime.utc(2030, 1, 20),
          ),
        ),
        'restore-submit',
      ),
      'restore lost': (
        const RestoreScreen(),
        const AuthFlowState(),
        'restore-back',
      ),
    };
    for (final entry in screens.entries) {
      final (screen, flow, key) = entry.value;
      await pumpUiMatrix(
        tester,
        (context) => _screen(screen, flow: flow),
        scales: const [2.0],
        sizes: const [Size(320, 568)],
        check: (tester, cell) async =>
            _expectPinnedAction(tester, cell, key, screenName: entry.key),
      );
    }
  });

  testWidgets('Consent is the second step of three', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(
        const RegistrationConsentScreen(),
        flow: const AuthFlowState(credentialsHeld: true),
      ),
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async {
        final l10n = lookupAppLocalizations(cell.locale);
        expect(find.text(l10n.stepOf(2, 3)), findsOneWidget);
      },
    );
  });

  testWidgets('Verify is the third step of three after a registration only', (
    tester,
  ) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(
        const VerifyScreen(),
        flow: const AuthFlowState(
          email: 'user@example.test',
          registering: true,
        ),
      ),
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async {
        final l10n = lookupAppLocalizations(cell.locale);
        expect(find.text(l10n.stepOf(3, 3)), findsOneWidget);
      },
    );
    await pumpUiMatrix(
      tester,
      (context) => _screen(
        const VerifyScreen(),
        flow: const AuthFlowState(email: 'user@example.test'),
      ),
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async {
        final l10n = lookupAppLocalizations(cell.locale);
        expect(find.text(l10n.stepOf(3, 3)), findsNothing);
        expect(find.text(l10n.stepOf(2, 2)), findsNothing);
      },
    );
  });

  testWidgets('password fields are hidden, empty and autofill-aware',
      (tester) async {
    TextField field(String key) =>
        tester.widget<TextField>(find.byKey(Key(key)));
    await pumpUiMatrix(
      tester,
      (context) => _screen(const RegisterScreen(), localData: false),
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async {
        expect(field('auth-password').obscureText, isTrue);
        expect(field('auth-password').controller?.text, isEmpty);
        expect(
          field('auth-password').autofillHints,
          const [AutofillHints.newPassword],
        );
        expect(field('auth-email').autofillHints, const [AutofillHints.email]);
        await tester.tap(find.byKey(const Key('auth-password-toggle')));
        await tester.pump();
        expect(field('auth-password').obscureText, isFalse);
      },
    );
    await pumpUiMatrix(
      tester,
      (context) => _screen(const LoginScreen(), localData: false),
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async => expect(
        field('auth-password').autofillHints,
        const [AutofillHints.password],
      ),
    );
    await pumpUiMatrix(
      tester,
      (context) => _screen(const VerifyScreen(), localData: false),
      scales: const [1.0],
      sizes: const [Size(360, 800)],
      check: (tester, cell) async => expect(
        field('auth-code').autofillHints,
        const [AutofillHints.oneTimeCode],
      ),
    );
  });

  testWidgets('the auth error is a persistent live region', (tester) async {
    final handle = tester.ensureSemantics();
    Future<void> pumpBanner(String? code) => tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Scaffold(body: AuthErrorBanner(code: code)),
          ),
        );
    Finder liveRegion() => find.descendant(
          of: find.byType(AuthErrorBanner),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is Semantics && widget.properties.liveRegion == true,
          ),
        );
    String label() => tester.getSemantics(find.byType(AuthErrorBanner)).label;

    await pumpBanner(null);
    expect(find.byKey(const Key('auth-error')), findsNothing);
    expect(liveRegion(), findsOneWidget);
    expect(label(), isEmpty);

    await pumpBanner('invalid_credentials');
    expect(find.byKey(const Key('auth-error')), findsOneWidget);
    expect(liveRegion(), findsOneWidget);
    final first = label();
    expect(first, isNotEmpty);

    await pumpBanner('rate_limited');
    expect(label(), isNot(first));
    expect(liveRegion(), findsOneWidget);
    handle.dispose();
  });

  testWidgets('EmptyState in the matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => SingleChildScrollView(
        child: EmptyState(
          icon: Icons.medication_outlined,
          message: 'Synthetic message',
          action: FilledButton(onPressed: () {}, child: const Text('Add')),
        ),
      ),
      expectTouchTargets: true,
    );
  });
}
