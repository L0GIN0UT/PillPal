import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/features/auth/auth_session.dart';
import 'package:pillpal/src/features/auth/welcome_screen.dart';
import 'package:pillpal/src/localization_delegates.dart';
import 'package:pillpal/src/theme/app_theme.dart';
import 'package:pillpal/src/theme/brand/pillpal_monogram.dart';
import 'package:pillpal/src/theme/palette.dart';
import 'package:pillpal/src/theme/radius.dart';

// Owner, 2026-11-11: the brand mark of Welcome is the one outlined mark, the
// border and the letter in the ink of the wordmark, with no fill.

void main() {
  for (final brightness in Brightness.values) {
    for (final senior in [false, true]) {
      testWidgets(
        'brand mark is outlined in ink (${brightness.name}, senior $senior)',
        (tester) async {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                hasBoundLocalDataProvider.overrideWith((ref) async => false),
              ],
              child: MaterialApp(
                theme: buildPillPalTheme(
                  brightness: brightness,
                  senior: senior,
                ),
                localizationsDelegates: pillPalLocalizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: const WelcomeScreen(),
              ),
            ),
          );
          await tester.pump();

          final ink = tester.element(find.byType(WelcomeScreen)).palette.ink;
          final tile = tester.widget<DecoratedBox>(
            find.byKey(const Key('welcome-brand')),
          );
          final decoration = tile.decoration as BoxDecoration;
          final border = decoration.border! as Border;
          expect(decoration.color, isNull);
          expect(decoration.borderRadius, PillPalRadius.control);
          expect(border.top.color, ink);
          expect(border.top.width, PillPalSizes.outline);
          expect(
            tester.getSize(find.byKey(const Key('welcome-brand'))),
            const Size.square(PillPalSizes.avatarMd),
          );

          final monogram = tester.widget<PillPalMonogram>(
            find.descendant(
              of: find.byKey(const Key('welcome-brand')),
              matching: find.byType(PillPalMonogram),
            ),
          );
          expect(monogram.color, ink);
          // The glyph box is centred in the tile, clear of the border.
          final tileRect = tester.getRect(
            find.byKey(const Key('welcome-brand')),
          );
          final glyphRect = tester.getRect(find.byWidget(monogram));
          expect(glyphRect.size, const Size.square(PillPalSizes.brandGlyph));
          expect(glyphRect.center, tileRect.center);
          expect(
            glyphRect.left - tileRect.left,
            greaterThan(PillPalSizes.outline),
          );
        },
      );
    }
  }
}
