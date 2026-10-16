import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/features/common/error_snack_bar.dart';

void main() {
  testWidgets('a failed action is shown, not lost', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => runShowingErrors(
                context,
                Future<void>.error(StateError('storage failed')),
              ),
              child: const Text('act'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('act'));
    await tester.pumpAndSettle();

    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(find.text(l10n.errorGeneric), findsOneWidget);
  });
}
