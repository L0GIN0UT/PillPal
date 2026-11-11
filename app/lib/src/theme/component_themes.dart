import 'package:flutter/material.dart';

import 'palette.dart';
import 'radius.dart';
import 'sizes.dart';
import 'spacing.dart';
import 'text_theme.dart';

/// Applies the component tokens of docs/design.md (B2-README section 3) to
/// [base]: buttons, cards, fields, navigation, selection controls, sheets
/// and dialogs. Everything reads [palette]; nothing here is a screen colour.
ThemeData applyComponentThemes(
  ThemeData base,
  PillPalPalette palette, {
  required bool senior,
}) {
  final text = base.textTheme;
  final touch =
      senior ? PillPalSizes.seniorButtonHeight : PillPalSizes.touchTarget;
  final dark = base.brightness == Brightness.dark;
  // Level 2 shadows are drawn by Material in light themes only.
  final lift = dark ? 0.0 : PillPalSizes.elevationLevel2;
  final scrim = palette.scrim.withValues(alpha: PillPalSizes.scrimOpacity);
  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: palette.background,
      foregroundColor: palette.ink,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      // An icon button in the bar is a touch target of the mode too.
      toolbarHeight: senior ? PillPalSizes.seniorButtonHeight : null,
      titleTextStyle: text.titleLarge,
    ),
    // Interim (until PillPalCard in R2 draws the shadow): a hairline keeps
    // cards visible on the background.
    cardTheme: CardThemeData(
      color: palette.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      // Ink splashes of a ListTile follow the rounded corners.
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: PillPalRadius.card,
        side: BorderSide(color: palette.border),
      ),
    ),
    // Material's rows (56, 72, 88) stay under the 64 of senior mode. A
    // non-null minTileHeight replaces those defaults, so only senior sets it.
    listTileTheme: ListTileThemeData(
      // The title of a switch or list tile reads like a PillPalListRow title.
      titleTextStyle: text.rowTitle,
      minTileHeight: senior ? PillPalSizes.seniorButtonHeight : null,
    ),
    filledButtonTheme: _filledButtons(palette, text, senior: senior),
    outlinedButtonTheme: _outlinedButtons(palette, text, senior: senior),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: Size(touch, touch),
        shape: PillPalRadius.pill,
        textStyle: text.labelLarge,
        foregroundColor: palette.action,
        disabledForegroundColor: palette.inkMuted,
      ),
    ),
    elevatedButtonTheme: _elevatedButtons(palette, text, senior: senior),
    inputDecorationTheme: _inputTheme(palette, text),
    navigationBarTheme: _navigationBarTheme(palette, text, senior: senior),
    segmentedButtonTheme: _segmentedTheme(
      palette,
      text,
      touch: touch,
      lift: dark ? 0 : PillPalSizes.elevationLevel1,
    ),
    switchTheme: _switchTheme(palette),
    checkboxTheme: _checkboxTheme(palette),
    radioTheme: _radioTheme(palette),
    chipTheme: _chipTheme(palette, text),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: palette.action,
      foregroundColor: palette.onAction,
      elevation: lift,
      focusElevation: lift,
      hoverElevation: lift,
      highlightElevation: lift,
      shape: PillPalRadius.pill,
      extendedTextStyle: text.labelLarge,
      extendedSizeConstraints: BoxConstraints.tightFor(
        height: senior ? PillPalSizes.fabSenior : PillPalSizes.fab,
      ),
    ),
    // Ink on background in every palette; a failed action is not a blocking
    // state, so it is not the danger colour.
    snackBarTheme: SnackBarThemeData(
      backgroundColor: palette.ink,
      contentTextStyle: text.bodyMedium?.copyWith(color: palette.background),
      actionTextColor: palette.background,
      behavior: SnackBarBehavior.floating,
      shape: const RoundedRectangleBorder(borderRadius: PillPalRadius.card),
    ),
    dividerTheme: DividerThemeData(color: palette.border, thickness: 1),
    dialogTheme: DialogThemeData(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      elevation: lift,
      barrierColor: scrim,
      shape: const RoundedRectangleBorder(borderRadius: PillPalRadius.dialog),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      elevation: lift,
      modalElevation: lift,
      showDragHandle: true,
      dragHandleSize: PillPalSizes.dragHandle,
      dragHandleColor:
          palette.outline.withValues(alpha: PillPalSizes.dragHandleOpacity),
      modalBarrierColor: scrim,
      shape: const RoundedRectangleBorder(
        borderRadius: PillPalRadius.sheetTop,
      ),
    ),
  );
}

double _buttonHeight(bool senior) =>
    senior ? PillPalSizes.seniorButtonHeight : PillPalSizes.buttonHeight;

FilledButtonThemeData _filledButtons(
  PillPalPalette palette,
  TextTheme text, {
  required bool senior,
}) {
  return FilledButtonThemeData(
    style: FilledButton.styleFrom(
      minimumSize: Size(PillPalSizes.buttonMinWidth, _buttonHeight(senior)),
      shape: PillPalRadius.pill,
      textStyle: text.labelLarge,
      // Enabled colours come from the colour scheme, so FilledButton.tonal
      // keeps its own pair.
      disabledBackgroundColor: palette.raised,
      disabledForegroundColor: palette.inkMuted,
    ),
  );
}

OutlinedButtonThemeData _outlinedButtons(
  PillPalPalette palette,
  TextTheme text, {
  required bool senior,
}) {
  return OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      minimumSize: Size(PillPalSizes.buttonMinWidth, _buttonHeight(senior)),
      shape: PillPalRadius.pill,
      textStyle: text.labelLarge,
      backgroundColor: palette.surface,
      foregroundColor: palette.ink,
      disabledForegroundColor: palette.inkMuted,
      side: BorderSide(color: palette.border, width: PillPalSizes.fieldBorder),
    ),
  );
}

/// No screen uses ElevatedButton; it follows the tonal button.
ElevatedButtonThemeData _elevatedButtons(
  PillPalPalette palette,
  TextTheme text, {
  required bool senior,
}) {
  return ElevatedButtonThemeData(
    style: ElevatedButton.styleFrom(
      minimumSize: Size(PillPalSizes.buttonMinWidth, _buttonHeight(senior)),
      shape: PillPalRadius.pill,
      textStyle: text.labelLarge,
      elevation: 0,
      backgroundColor: palette.actionSoft,
      foregroundColor: palette.onActionSoft,
      disabledBackgroundColor: palette.raised,
      disabledForegroundColor: palette.inkMuted,
    ),
  );
}

InputDecorationTheme _inputTheme(PillPalPalette palette, TextTheme text) {
  OutlineInputBorder border(Color color, double width) => OutlineInputBorder(
        borderRadius: PillPalRadius.control,
        borderSide: BorderSide(color: color, width: width),
      );
  final resting = border(palette.outline, PillPalSizes.fieldBorder);
  final error = border(palette.danger, PillPalSizes.outline);
  return InputDecorationTheme(
    filled: true,
    fillColor: palette.surface,
    border: resting,
    enabledBorder: resting,
    disabledBorder: border(palette.border, PillPalSizes.fieldBorder),
    focusedBorder: border(palette.action, PillPalSizes.outline),
    errorBorder: error,
    focusedErrorBorder: error,
    hintStyle: text.bodyLarge?.copyWith(color: palette.inkMuted),
    helperStyle: text.bodySmall,
    errorStyle: text.bodySmall?.copyWith(color: palette.danger),
    prefixIconColor: palette.inkMuted,
    suffixIconColor: palette.inkMuted,
  );
}

NavigationBarThemeData _navigationBarTheme(
  PillPalPalette palette,
  TextTheme text, {
  required bool senior,
}) {
  bool selected(Set<WidgetState> states) =>
      states.contains(WidgetState.selected);
  return NavigationBarThemeData(
    height: senior ? PillPalSizes.navHeightSenior : PillPalSizes.navHeight,
    backgroundColor: palette.surface,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    indicatorColor: palette.actionSoft,
    indicatorShape: const RoundedRectangleBorder(
      borderRadius:
          BorderRadius.all(Radius.circular(PillPalRadius.navIndicator)),
    ),
    labelTextStyle: WidgetStateProperty.resolveWith(
      (states) => text.labelSmall?.copyWith(
        fontWeight: selected(states) ? FontWeight.w700 : FontWeight.w500,
        color: selected(states) ? palette.onActionSoft : palette.inkMuted,
      ),
    ),
    iconTheme: WidgetStateProperty.resolveWith(
      (states) => IconThemeData(
        color: selected(states) ? palette.onActionSoft : palette.inkMuted,
      ),
    ),
  );
}

SegmentedButtonThemeData _segmentedTheme(
  PillPalPalette palette,
  TextTheme text, {
  required double touch,
  required double lift,
}) {
  bool selected(Set<WidgetState> states) =>
      states.contains(WidgetState.selected);
  return SegmentedButtonThemeData(
    style: ButtonStyle(
      minimumSize: WidgetStatePropertyAll(Size(touch, touch)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: PillPalSpacing.sm),
      ),
      shape: const WidgetStatePropertyAll(PillPalRadius.pill),
      // Interim (until PillPalSegmented in R2 draws the track): a visible edge.
      side: WidgetStatePropertyAll(BorderSide(color: palette.border)),
      elevation: WidgetStateProperty.resolveWith(
        (states) => selected(states) ? lift : 0,
      ),
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) => selected(states) ? palette.surface : Colors.transparent,
      ),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => selected(states) ? palette.ink : palette.inkMuted,
      ),
      textStyle: WidgetStateProperty.resolveWith(
        (states) => text.segmentLabel(selected: selected(states)),
      ),
    ),
  );
}

SwitchThemeData _switchTheme(PillPalPalette palette) {
  bool on(Set<WidgetState> states) => states.contains(WidgetState.selected);
  bool disabled(Set<WidgetState> states) =>
      states.contains(WidgetState.disabled);
  return SwitchThemeData(
    trackColor: WidgetStateProperty.resolveWith(
      (states) =>
          on(states) && !disabled(states) ? palette.action : palette.raised,
    ),
    thumbColor: WidgetStateProperty.resolveWith(
      (states) => disabled(states)
          ? palette.inkMuted
          : on(states)
              ? palette.onAction
              : palette.outline,
    ),
    trackOutlineColor: WidgetStateProperty.resolveWith(
      (states) => disabled(states)
          ? palette.border
          : on(states)
              ? Colors.transparent
              : palette.outline,
    ),
    trackOutlineWidth: WidgetStateProperty.resolveWith(
      (states) => on(states) && !disabled(states) ? 0 : PillPalSizes.outline,
    ),
  );
}

CheckboxThemeData _checkboxTheme(PillPalPalette palette) {
  bool on(Set<WidgetState> states) => states.contains(WidgetState.selected);
  bool disabled(Set<WidgetState> states) =>
      states.contains(WidgetState.disabled);
  return CheckboxThemeData(
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(PillPalRadius.checkbox),
    ),
    checkColor: WidgetStatePropertyAll(palette.onAction),
    fillColor: WidgetStateProperty.resolveWith(
      (states) => on(states)
          ? (disabled(states) ? palette.border : palette.action)
          : Colors.transparent,
    ),
    side: WidgetStateBorderSide.resolveWith(
      (states) => on(states)
          ? BorderSide.none
          : BorderSide(
              color: disabled(states) ? palette.border : palette.outline,
              width: PillPalSizes.outline,
            ),
    ),
  );
}

RadioThemeData _radioTheme(PillPalPalette palette) {
  return RadioThemeData(
    fillColor: WidgetStateProperty.resolveWith(
      (states) => states.contains(WidgetState.disabled)
          ? palette.border
          : states.contains(WidgetState.selected)
              ? palette.action
              : palette.outline,
    ),
  );
}

ChipThemeData _chipTheme(PillPalPalette palette, TextTheme text) {
  bool selected(Set<WidgetState> states) =>
      states.contains(WidgetState.selected);
  return ChipThemeData(
    shape: PillPalRadius.pill,
    backgroundColor: palette.surface,
    selectedColor: palette.actionSoft,
    checkmarkColor: palette.onActionSoft,
    side: WidgetStateBorderSide.resolveWith(
      (states) => selected(states)
          ? BorderSide.none
          : BorderSide(color: palette.border, width: PillPalSizes.hairline),
    ),
    labelStyle: text.labelMedium?.copyWith(
      color: WidgetStateColor.resolveWith(
        (states) => selected(states) ? palette.onActionSoft : palette.ink,
      ),
    ),
  );
}
