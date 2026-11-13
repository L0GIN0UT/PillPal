import 'package:material_ui/material_ui.dart';

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

  /// Icon next to inline text.
  static const double iconInline = 20;

  /// Icon in senior mode rows.
  static const double iconSenior = 28;

  /// Icon of a hero block (welcome, status).
  static const double iconHero = 40;

  /// Box of the brand monogram inside the 48 tile of Welcome (the glyph fills
  /// about 85% of it).
  static const double brandGlyph = 32;

  /// Progress spinner inside a button.
  static const double spinner = 24;

  /// Stroke of that spinner.
  static const double spinnerStroke = 2;

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

  /// The most a sticky bar may take of the screen height for its messages
  /// (schedule errors); the rest of the bar keeps the button on screen.
  static const double stickyBarMaxFraction = 0.35;

  /// The width two date fields side by side need (course dates); narrower
  /// they stack, so 320 and 360 px phones always stack.
  static const double dateFieldPairMinWidth = 340;

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

  /// Icon inside a status pill (B2-README section 3).
  static const double statusIcon = 16;

  /// Check icon of the selected profile chip.
  static const double chipIcon = 16;

  /// Widest a profile chip label grows before it is cut with an ellipsis.
  static const double chipLabelMaxWidth = 160;

  /// Width of the fade to `bg` at the end of a scrolling row of chips.
  static const double chipFade = 32;

  /// Least height of a stacked button at a large text scale (section 9.6).
  static const double stackedButtonMin = 56;

  /// Round marker of the History legend.
  static const double legendMarker = 16;

  /// Round marker of the History legend in senior mode.
  static const double legendMarkerSenior = 24;

  /// Diameter of a status disc (icon + word status, normal mode).
  static const double statusDisc = 40;

  /// Width of the ring of a pending status disc in senior mode (colour
  /// `inkMuted`, 3:1 on `surface`).
  static const double statusRingSenior = 2;

  /// Diameter of a status disc in senior mode.
  static const double statusDiscSenior = 52;

  /// Diameter of the round check button of an upcoming dose.
  static const double roundCheck = 48;

  /// Where the label of a `PillPalCheckTile` starts: the 40 leading width and
  /// the 16 gap `CheckboxListTile` leaves before its title. A link or note
  /// under the label starts here. `pillpal_check_tile_test` compares it with
  /// the real label, so a change of the tile fails there.
  static const double checkTileLabelIndent = 40 + 16;

  /// Height of a profile chip.
  static const double profileChip = 44;

  /// Height of the navigation bar in normal mode.
  static const double navHeight = 88;

  /// Height of the navigation bar in senior mode.
  static const double navHeightSenior = 104;

  /// Padding inside the «Сейчас» card.
  static const double heroPadding = 20;

  /// Opacity of the outline of the secondary button inside the «Сейчас» card
  /// (the colour is `onHero`; B2-README section 3, `hero`).
  static const double heroOutlineOpacity = 0.55;

  /// Height of the extended floating button.
  static const double fab = 56;

  /// Height of the extended floating button in senior mode.
  static const double fabSenior = 64;

  /// Elevation of the floating button and, in light themes, of sheets and
  /// dialogs (level 2); dark themes have none.
  static const double elevationLevel2 = 2;

  /// Elevation of the selected segment (level 1, light only).
  static const double elevationLevel1 = 1;

  /// Least width of a button.
  static const double buttonMinWidth = 64;

  /// Avatar diameters: lists, family rows, relative header.
  static const double avatarSm = 40;

  /// Avatar of a family row.
  static const double avatarMd = 48;

  /// Avatar of the relative header.
  static const double avatarLg = 64;

  /// Height of a status pill.
  static const double statusPill = 28;

  /// Height of a chip (a profile chip is [profileChip]).
  static const double chipHeight = 36;

  /// Least height of a list row.
  static const double listRowMin = 60;

  /// Least height of a person row (avatar, name, status; board B-Family).
  static const double personRowMin = 72;

  /// Least height of a list row in senior mode.
  static const double listRowMinSenior = 76;

  /// Vertical padding of a banner.
  static const double bannerPaddingVertical = 14;

  /// Horizontal padding of a banner.
  static const double bannerPaddingHorizontal = 16;

  /// Side of a QR code.
  static const double qrCode = 220;

  /// Largest share of the screen height a sheet of fixed height takes
  /// (`SheetScaffold.fill`).
  static const double sheetMaxHeightFactor = 0.9;

  /// Least content height of a sheet of fixed height at text x1 (scaled
  /// with the text): below it, on a short screen with the keyboard up, the
  /// whole sheet scrolls instead of squeezing its body to nothing.
  static const double sheetMinContentHeight = 280;

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

  /// Largest text scale of the navigation labels in senior mode, whose
  /// system multiplier already counts (the label keeps its normal size).
  static const double navLabelSeniorMaxScale = 1.0;

  /// Largest text scale of the label of the floating button.
  static const double fabLabelMaxScale = 1.3;

  /// From this text scale on, layouts go compact: list rows hide their tile
  /// and chevron, the Today header moves its actions to their own line and
  /// trades the ring for a counter line, pills drop under the text.
  static const double compactScale = 1.6;

  /// Minimum height of an empty state that centres itself in a list.
  static const double emptyStateMinHeight = 360;

  /// From this text scale on, a pair of buttons or tiles of the add flow
  /// (scan / manual, camera / continue) goes one under the other. The boards
  /// show such pairs side by side at the normal scale, and B2-README section
  /// 9.6 stacks pairs always; this is the recorded exception: two columns of
  /// about 140 px hold a Russian label up to about x1.2.
  static const double pairStackScale = 1.25;

  /// Height of the camera view of the scan sheet (board B2-ScanCamera).
  static const double scanViewfinderHeight = 300;

  /// The frame the code is aimed at, inside the camera view.
  static const Size scanFrame = Size(250, 150);

  /// Side of a corner mark of the scan frame.
  static const double scanMarkSize = 36;

  /// Stroke of a corner mark of the scan frame.
  static const double scanMarkStroke = 4;

  /// Minimum height of an entry tile of the add form (scan / manual).
  static const double entryTileMin = 88;
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

  /// Whether these are the metrics of senior mode.
  bool get isSenior => touchTarget > PillPalSizes.touchTarget;

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

  /// Whether a pair of buttons has to be stacked at the current text scale
  /// ([PillPalSizes.pairStackScale]).
  bool get stacksPair =>
      MediaQuery.textScalerOf(this).scale(1) >= PillPalSizes.pairStackScale;
}
