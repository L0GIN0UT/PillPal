import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/features/common/error_snack_bar.dart';
import 'package:pillpal/src/theme/app_theme.dart';
import 'package:pillpal/src/theme/palette.dart';

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

  testWidgets('the snack bar is ink on background, never danger',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildPillPalTheme(brightness: Brightness.light, senior: false),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showErrorSnackBar(context),
              child: const Text('act'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('act'));
    await tester.pumpAndSettle();

    const palette = PillPalPalette.light;
    final bar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(bar.backgroundColor, palette.ink);
    final text = tester.widget<Text>(
      find.descendant(of: find.byType(SnackBar), matching: find.byType(Text)),
    );
    expect(text.style?.color, palette.background);
  });
}
