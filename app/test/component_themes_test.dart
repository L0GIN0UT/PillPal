import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/theme/app_theme.dart';
import 'package:pillpal/src/theme/palette.dart';
import 'package:pillpal/src/theme/radius.dart';

double _buttonHeight(ThemeData theme) {
  final size = theme.filledButtonTheme.style?.minimumSize?.resolve({});
  return size?.height ?? 0;
}

ThemeData _theme(Brightness brightness, {bool senior = false}) =>
    buildPillPalTheme(brightness: brightness, senior: senior);

void main() {
  test('buttons are stadium shaped with unchanged heights', () {
    for (final senior in [false, true]) {
      final theme = _theme(Brightness.light, senior: senior);
      final shapes = [
        theme.filledButtonTheme.style?.shape,
        theme.outlinedButtonTheme.style?.shape,
        theme.textButtonTheme.style?.shape,
        theme.elevatedButtonTheme.style?.shape,
      ];
      for (final shape in shapes) {
        expect(shape?.resolve({}), isA<StadiumBorder>());
      }
      final expected =
          senior ? PillPalSizes.seniorButtonHeight : PillPalSizes.buttonHeight;
      expect(_buttonHeight(theme), expected);
      final touch =
          senior ? PillPalSizes.seniorButtonHeight : PillPalSizes.touchTarget;
      final text = theme.textButtonTheme.style?.minimumSize?.resolve({});
      expect(text, Size(touch, touch));
    }
  });

  test('the secondary button has a 1.5 border ring on surface', () {
    final theme = _theme(Brightness.light);
    final palette = PillPalPalette.light;
    final side = theme.outlinedButtonTheme.style?.side?.resolve({});
    expect(side?.color, palette.border);
    expect(side?.width, 1.5);
    final style = theme.outlinedButtonTheme.style;
    expect(style?.backgroundColor?.resolve({}), palette.surface);
    expect(style?.foregroundColor?.resolve({}), palette.ink);
  });

  test('disabled buttons use raised and inkMuted', () {
    final theme = _theme(Brightness.dark);
    final style = theme.filledButtonTheme.style;
    final palette = PillPalPalette.dark;
    final disabled = {WidgetState.disabled};
    expect(style?.backgroundColor?.resolve(disabled), palette.raised);
    expect(style?.foregroundColor?.resolve(disabled), palette.inkMuted);
  });

  test('cards have radius 20, a hairline (interim) and no elevation', () {
    final card = _theme(Brightness.light).cardTheme;
    final shape = card.shape as RoundedRectangleBorder;
    expect(shape.borderRadius, PillPalRadius.card);
    // Interim until PillPalCard draws the shadow in R2.
    expect(shape.side, BorderSide(color: PillPalPalette.light.border));
    expect(card.elevation, 0);
  });

  test('sheets, dialogs, FAB and chips use the shape tokens', () {
    final theme = _theme(Brightness.light);
    final palette = PillPalPalette.light;
    final dialog = theme.dialogTheme.shape as RoundedRectangleBorder;
    expect(dialog.borderRadius, PillPalRadius.dialog);
    expect(theme.dialogTheme.backgroundColor, palette.surface);
    final sheet = theme.bottomSheetTheme.shape as RoundedRectangleBorder;
    expect(sheet.borderRadius, PillPalRadius.sheetTop);
    expect(theme.bottomSheetTheme.backgroundColor, palette.surface);
    expect(theme.bottomSheetTheme.showDragHandle, isTrue);
    expect(theme.bottomSheetTheme.dragHandleSize, const Size(36, 4));
    expect(
      theme.bottomSheetTheme.modalBarrierColor,
      palette.scrim.withValues(alpha: 0.48),
    );
    expect(theme.floatingActionButtonTheme.shape, isA<StadiumBorder>());
    expect(theme.floatingActionButtonTheme.elevation, 2);
    final darkFab = _theme(Brightness.dark).floatingActionButtonTheme;
    expect(darkFab.elevation, 0);
    expect(darkFab.highlightElevation, 0);
    for (final senior in [false, true]) {
      final fab = _theme(Brightness.light, senior: senior)
          .floatingActionButtonTheme
          .extendedSizeConstraints;
      expect(fab?.minHeight, senior ? 64 : 56);
    }
    expect(theme.chipTheme.shape, isA<StadiumBorder>());
    expect(theme.chipTheme.selectedColor, palette.selected);
    expect(theme.chipTheme.backgroundColor, palette.surface);
  });

  test('switch and checkbox boundaries use the outline token', () {
    final theme = _theme(Brightness.light);
    final palette = PillPalPalette.light;
    final off = <WidgetState>{};
    final on = {WidgetState.selected};
    final sw = theme.switchTheme;
    expect(sw.trackColor?.resolve(on), palette.action);
    expect(sw.thumbColor?.resolve(on), palette.onAction);
    expect(sw.trackColor?.resolve(off), palette.raised);
    expect(sw.thumbColor?.resolve(off), palette.outline);
    expect(sw.trackOutlineColor?.resolve(off), palette.outline);
    expect(sw.trackOutlineWidth?.resolve(off), 2);
    final box = theme.checkboxTheme;
    final boxShape = box.shape as RoundedRectangleBorder;
    expect(
        boxShape.borderRadius, BorderRadius.circular(PillPalRadius.checkbox));
    expect(box.fillColor?.resolve(on), palette.action);
    expect(box.checkColor?.resolve(on), palette.onAction);
    final boxSide = (box.side! as WidgetStateBorderSide).resolve(off);
    expect(boxSide?.color, palette.outline);
    expect(boxSide?.width, 2);
  });

  test('segments are stadium, 44 / 64 high, surface when selected', () {
    for (final senior in [false, true]) {
      final theme = _theme(Brightness.light, senior: senior);
      final palette = theme.extension<PillPalPalette>()!;
      final style = theme.segmentedButtonTheme.style!;
      final selected = {WidgetState.selected};
      final touch = senior ? 64.0 : 44.0;
      expect(style.minimumSize?.resolve({}), Size(touch, touch));
      expect(style.shape?.resolve({}), isA<StadiumBorder>());
      expect(style.backgroundColor?.resolve(selected), palette.surface);
      expect(style.foregroundColor?.resolve(selected), palette.ink);
      expect(style.foregroundColor?.resolve({}), palette.inkMuted);
      expect(style.elevation?.resolve(selected), 1);
      // Interim until PillPalSegmented draws the track in R2.
      expect(style.side?.resolve({})?.color, palette.border);
      expect(style.textStyle?.resolve(selected)?.fontWeight, FontWeight.w700);
    }
    final dark = _theme(Brightness.dark).segmentedButtonTheme.style!;
    expect(dark.elevation?.resolve({WidgetState.selected}), 0);
  });

  test('inputs are filled with outline, action focus and danger error', () {
    final theme = _theme(Brightness.light);
    final palette = PillPalPalette.light;
    final input = theme.inputDecorationTheme;
    expect(input.filled, isTrue);
    expect(input.fillColor, palette.surface);
    void expectBorder(InputBorder? border, Color color, double width) {
      final outline = border as OutlineInputBorder;
      expect(outline.borderRadius, PillPalRadius.control);
      expect(outline.borderSide.color, color);
      expect(outline.borderSide.width, width);
    }

    expectBorder(input.enabledBorder, palette.outline, 1.5);
    expectBorder(input.border, palette.outline, 1.5);
    expectBorder(input.focusedBorder, palette.action, 2);
    expectBorder(input.errorBorder, palette.danger, 2);
    expectBorder(input.focusedErrorBorder, palette.danger, 2);
  });

  test('the navigation bar is 88 / 104 with a 16 indicator', () {
    for (final senior in [false, true]) {
      final theme = _theme(Brightness.light, senior: senior);
      final palette = theme.extension<PillPalPalette>()!;
      final nav = theme.navigationBarTheme;
      expect(nav.height, senior ? 104 : 88);
      expect(nav.backgroundColor, palette.surface);
      expect(nav.indicatorColor, palette.selected);
      final shape = nav.indicatorShape as RoundedRectangleBorder;
      expect(
        shape.borderRadius,
        BorderRadius.circular(PillPalRadius.navIndicator),
      );
      final active = nav.labelTextStyle?.resolve({WidgetState.selected});
      final idle = nav.labelTextStyle?.resolve({});
      expect(active?.fontWeight, FontWeight.w700);
      expect(idle?.fontWeight, FontWeight.w500);
      expect(idle?.color, palette.inkMuted);
    }
  });

  test('colorScheme maps the semantic tokens', () {
    for (final brightness in Brightness.values) {
      for (final senior in [false, true]) {
        final theme = _theme(brightness, senior: senior);
        final p = theme.extension<PillPalPalette>()!;
        final scheme = theme.colorScheme;
        expect(scheme.primary, p.action);
        expect(scheme.onPrimary, p.onAction);
        expect(scheme.secondaryContainer, p.actionSoft);
        expect(scheme.onSecondaryContainer, p.onActionSoft);
        expect(scheme.error, p.danger);
        expect(scheme.onError, p.onDanger);
        expect(scheme.surface, p.surface);
        expect(scheme.onSurface, p.ink);
        expect(scheme.onSurfaceVariant, p.inkMuted);
        expect(scheme.surfaceContainerHighest, p.raised);
        expect(scheme.outline, p.outline);
        expect(scheme.outlineVariant, p.border);
        expect(scheme.scrim, p.scrim);
        expect(theme.scaffoldBackgroundColor, p.background);
      }
    }
  });

  test('the light selection is the tonal pair, as before', () {
    for (final senior in [false, true]) {
      final theme = _theme(Brightness.light, senior: senior);
      final palette = theme.extension<PillPalPalette>()!;
      final nav = theme.navigationBarTheme;
      expect(palette.selected, palette.actionSoft);
      expect(palette.onSelected, palette.onActionSoft);
      expect(nav.indicatorColor, palette.actionSoft);
      expect(
        nav.labelTextStyle?.resolve({WidgetState.selected})?.color,
        palette.onActionSoft,
      );
    }
  });

  test('in dark themes every selection is the solid action pair', () {
    for (final senior in [false, true]) {
      final theme = _theme(Brightness.dark, senior: senior);
      final palette = theme.extension<PillPalPalette>()!;
      final nav = theme.navigationBarTheme;
      expect(palette.selected, palette.action);
      expect(palette.onSelected, palette.onAction);
      expect(nav.indicatorColor, palette.selected);
      expect(
        nav.labelTextStyle?.resolve({WidgetState.selected})?.color,
        palette.onSelected,
      );
      expect(
        nav.iconTheme?.resolve({WidgetState.selected})?.color,
        palette.onSelected,
      );
      expect(theme.chipTheme.selectedColor, palette.selected);
      expect(theme.chipTheme.checkmarkColor, palette.onSelected);
    }
  });
}
