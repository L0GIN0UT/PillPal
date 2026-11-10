import 'package:flutter/material.dart';

import 'radius.dart';

/// Size tokens; senior mode scales touch targets (docs/design.md).
abstract final class PillPalSizes {
  /// Minimum button height in normal mode.
  static const double buttonHeight = 52;

  /// Minimum button height in senior mode.
  static const double seniorButtonHeight = 64;

  /// Minimum touch target in normal mode (docs/design.md: >= 44).
  static const double touchTarget = 44;

  /// Text scale multiplier applied on top of the system scale in senior mode.
  static const double seniorTextScale = 1.3;

  /// Deprecated: use [PillPalRadius.lg]. Removed in R8.
  static const double cardRadius = PillPalRadius.lg;

  /// Deprecated: use [PillPalRadius.md]. Removed in R8.
  static const double controlRadius = PillPalRadius.md;

  /// Deprecated: use [PillPalRadius.xl]. Removed in R8.
  static const double sheetRadius = PillPalRadius.xl;

  /// Icon next to inline text.
  static const double iconInline = 20;

  /// Icon in senior mode rows.
  static const double iconSenior = 28;

  /// Icon of a hero block (welcome, status).
  static const double iconHero = 40;

  /// Progress spinner inside a button.
  static const double spinner = 24;

  /// Icon of an empty state, inside the [emptyDisc].
  static const double iconEmpty = 44;

  /// Diameter of the soft disc of an empty state.
  static const double emptyDisc = 96;

  /// Width of outlines: fields, outlined buttons, info and danger banners.
  static const double outline = 2;

  /// Width of the resting boundary of a field and of the secondary button.
  static const double fieldBorder = 1.5;

  /// Side of the Today progress ring at normal text scale.
  static const double progressRing = 56;

  /// Height of the line of a label/value row (course dates).
  static const double infoRowHeight = 54;

  /// Height of the unit menu of a schedule time slot.
  static const double unitPickerHeight = 48;

  /// Thickness and height of a hairline divider inside a card.
  static const double hairline = 1;

  /// Room a list leaves at its bottom for an extended floating button
  /// (56, 64 in senior mode, plus its 16 margin and some air).
  static const double fabClearance = 96;

  /// Width of the dose amount field of a schedule time slot.
  static const double doseAmountWidth = 80;

  /// Least width of the time column of a dose tile.
  static const double doseTimeWidth = 52;

  /// Least width a dose tile keeps for time, name and dose at normal text
  /// scale (it grows with the scale) when the status sits beside them;
  /// below it the status moves under the text.
  static const double doseSummaryMinWidth = 160;

  /// Height of the large "Taken" button of the senior "take now" card.
  static const double seniorTakeHeight = 76;

  /// Status mark inside a History calendar cell.
  static const double calendarMark = 12;

  /// Status mark inside a History calendar cell in senior mode.
  static const double calendarMarkSenior = 18;

  /// Round marker of the History legend.
  static const double legendMarker = 16;

  /// Round marker of the History legend in senior mode.
  static const double legendMarkerSenior = 24;

  /// Deprecated: use [statusDiscSenior] (52). Kept at the old 64 until the
  /// senior Today screen moves to the disc in R3b; counted by
  /// `.github/scripts/check_ui_tokens.py`.
  static const double statusSquare = 64;

  /// Diameter of a status disc (icon + word status, normal mode).
  static const double statusDisc = 40;

  /// Diameter of a status disc in senior mode.
  static const double statusDiscSenior = 52;

  /// Diameter of the round check button of an upcoming dose.
  static const double roundCheck = 48;

  /// Height of a profile chip.
  static const double profileChip = 44;

  /// Height of the navigation bar in normal mode.
  static const double navHeight = 88;

  /// Height of the navigation bar in senior mode.
  static const double navHeightSenior = 104;

  /// Padding inside the «Сейчас» card.
  static const double heroPadding = 20;

  /// Height of the extended floating button.
  static const double fab = 56;

  /// Side of a QR code.
  static const double qrCode = 220;

  /// Width and height of the drag handle of a bottom sheet.
  static const Size dragHandle = Size(36, 4);

  /// Opacity of the drag handle of a bottom sheet.
  static const double dragHandleOpacity = 0.6;

  /// Opacity of the scrim behind sheets and dialogs.
  static const double scrimOpacity = 0.48;

  /// Largest text scale of a screen title (B2-README section 9).
  static const double titleMaxScale = 1.5;

  /// Largest text scale of the medication name in the «Сейчас» card.
  static const double heroNameMaxScale = 1.6;

  /// Largest text scale of the navigation labels.
  static const double navLabelMaxScale = 1.15;

  /// Largest text scale of the label of the floating button.
  static const double fabLabelMaxScale = 1.3;

  /// From this text scale on, list rows hide their tile and chevron.
  static const double compactRowScale = 1.6;

  /// Minimum height of an empty state that centres itself in a list.
  static const double emptyStateMinHeight = 360;
}

/// Size metrics of the current mode, for widgets that size touch targets
/// themselves (chips, calendar cells, inline buttons).
@immutable
class PillPalMetrics extends ThemeExtension<PillPalMetrics> {
  /// Creates metrics.
  const PillPalMetrics({required this.touchTarget});

  /// Normal mode.
  static const PillPalMetrics normal =
      PillPalMetrics(touchTarget: PillPalSizes.touchTarget);

  /// Senior mode: touch targets of at least 64 (docs/design.md).
  static const PillPalMetrics senior =
      PillPalMetrics(touchTarget: PillPalSizes.seniorButtonHeight);

  /// Minimum width and height of a touch target.
  final double touchTarget;

  @override
  PillPalMetrics copyWith({double? touchTarget}) =>
      PillPalMetrics(touchTarget: touchTarget ?? this.touchTarget);

  @override
  PillPalMetrics lerp(ThemeExtension<PillPalMetrics>? other, double t) =>
      other is PillPalMetrics && t >= 0.5 ? other : this;
}

/// Access to [PillPalMetrics] of the current theme.
extension PillPalMetricsOf on BuildContext {
  /// The current metrics (normal when the theme has none).
  PillPalMetrics get metrics =>
      Theme.of(this).extension<PillPalMetrics>() ?? PillPalMetrics.normal;
}
