import 'package:flutter/widgets.dart';

/// Corner radius tokens of the «Абрикос» design system: 12 / 16 / 18 / 24
/// (design canvas "Радиусы"). Pills use [StadiumBorder] instead.
abstract final class PillPalRadius {
  /// 12: chips, calendar cells, badges, small icon tiles.
  static const double sm = 12;

  /// 16: buttons and fields.
  static const double md = 16;

  /// 18: cards.
  static const double lg = 18;

  /// 24: dialogs and bottom sheets.
  static const double xl = 24;

  /// Cards.
  static const BorderRadius card = BorderRadius.all(Radius.circular(lg));

  /// Buttons and fields.
  static const BorderRadius control = BorderRadius.all(Radius.circular(md));

  /// Chips, calendar cells, badges.
  static const BorderRadius chip = BorderRadius.all(Radius.circular(sm));

  /// Dialogs.
  static const BorderRadius dialog = BorderRadius.all(Radius.circular(xl));

  /// Top corners of a bottom sheet.
  static const BorderRadius sheetTop =
      BorderRadius.vertical(top: Radius.circular(xl));
}
