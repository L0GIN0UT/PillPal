import 'package:flutter/widgets.dart';

/// Corner radius tokens of the «Забота» design system: 12 / 16 / 20 / 28 and
/// the pill (docs/design.md, B2-README section 6).
abstract final class PillPalRadius {
  /// 12: calendar cells, small tiles, keypad keys.
  static const double sm = 12;

  /// 16: fields and tonal tiles.
  static const double md = 16;

  /// 20: cards and banners.
  static const double lg = 20;

  /// 28: sheets, dialogs and the «Сейчас» card.
  static const double xl = 28;

  /// 16: the indicator of the selected navigation destination.
  static const double navIndicator = 16;

  /// 7: the box of a checkbox.
  static const double checkbox = 7;

  /// Every button, chip, pill, segmented control, FAB.
  static const StadiumBorder pill = StadiumBorder();

  /// Cards.
  static const BorderRadius card = BorderRadius.all(Radius.circular(lg));

  /// Fields and tonal tiles.
  static const BorderRadius control = BorderRadius.all(Radius.circular(md));

  /// Calendar cells and small tiles.
  static const BorderRadius chip = BorderRadius.all(Radius.circular(sm));

  /// Prominent blocks: the «Сейчас» card (28, like dialogs).
  static const BorderRadius hero = BorderRadius.all(Radius.circular(xl));

  /// Dialogs.
  static const BorderRadius dialog = BorderRadius.all(Radius.circular(xl));

  /// Top corners of a bottom sheet.
  static const BorderRadius sheetTop =
      BorderRadius.vertical(top: Radius.circular(xl));
}
