import 'package:flutter/widgets.dart';

/// Spacing tokens of the «Абрикос» design system: multiples of 4
/// (docs/design.md). Screens use these instead of literal numbers.
abstract final class PillPalSpacing {
  /// 4: icon and label, tight rows.
  static const double xs = 4;

  /// 8: related controls.
  static const double sm = 8;

  /// 12: items of a list, label and field.
  static const double md = 12;

  /// 16: card padding, groups.
  static const double lg = 16;

  /// 20: screen side padding.
  static const double xl = 20;

  /// 24: sections.
  static const double xxl = 24;

  /// 32: bottom of a scrolling screen.
  static const double xxxl = 32;

  /// Padding inside a card.
  static const EdgeInsets card = EdgeInsets.all(lg);

  /// Padding of a scrolling form screen.
  static const EdgeInsets form = EdgeInsets.fromLTRB(xl, sm, xl, xxxl);

  /// Padding of the content of a bottom sheet.
  static const EdgeInsets sheet = EdgeInsets.fromLTRB(xl, 0, xl, xl);

  /// Padding of a list tab (Medications, History, ...).
  static const EdgeInsets screen = EdgeInsets.fromLTRB(xl, sm, xl, xxl);

  /// Padding of the header of Today and Family.
  static const EdgeInsets tabHeader = EdgeInsets.fromLTRB(xl, xxl, xl, xxl);

  /// Gap between chips of a choice group (spacing and run spacing).
  static const double chips = sm;
}
