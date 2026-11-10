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

  test('the theme draws the snack bar as ink on background, floating', () {
    for (final brightness in Brightness.values) {
      final theme = buildPillPalTheme(brightness: brightness, senior: false);
      final palette = brightness == Brightness.light
          ? PillPalPalette.light
          : PillPalPalette.dark;
      final bar = theme.snackBarTheme;
      expect(bar.backgroundColor, palette.ink);
      expect(bar.contentTextStyle?.color, palette.background);
      expect(bar.actionTextColor, palette.background);
      expect(bar.behavior, SnackBarBehavior.floating);
    }
  });
}
