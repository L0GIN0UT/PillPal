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
        expect(
          find.byKey(const Key('region-other-later')),
          cell.locale.languageCode == 'en' ? findsOneWidget : findsNothing,
          reason: 'region note in "${cell.label}"',
        );
        for (final key in [
          'welcome-register',
          'welcome-login',
          'region-build',
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
      check: _expectKeys(['auth-email', 'auth-password', 'auth-submit']),
    );
  });

  testWidgets('Verify in the matrix', (tester) async {
    await pumpUiMatrix(
      tester,
      (context) => _screen(
        const VerifyScreen(),
        flow: const AuthFlowState(
          email: 'user@example.test',
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
