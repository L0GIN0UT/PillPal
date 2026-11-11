import 'package:flutter/widgets.dart';

/// Spacing tokens of the «Забота» design system: multiples of 4
/// (docs/design.md). Screens use these instead of literal numbers.
abstract final class PillPalSpacing {
  /// 4: icon and label, tight rows.
  static const double xs = 4;

  /// 8: related controls.
  static const double sm = 8;

  /// 12: items of a list, label and field.
  static const double md = 12;

  /// 16: card padding, groups, side padding of the tabs.
  static const double lg = 16;

  /// 20: side padding of pushed screens, forms and sheets.
  static const double xl = 20;

  /// 24: sections.
  static const double xxl = 24;

  /// 32: bottom of a scrolling screen.
  static const double xxxl = 32;

  /// 40: large gaps (welcome, empty states).
  static const double huge = 40;

  /// Space above a section header.
  static const double sectionTop = xxl;

  /// Space between a section header and its content (the board draws 10,
  /// which is off the 4-scale; rounded to [md] as docs/redesign-plan.md says).
  static const double sectionBottom = md;

  /// Padding inside a card.
  static const EdgeInsets card = EdgeInsets.all(lg);

  /// Padding of a block (label and control) in a card, like a list row.
  static const EdgeInsets cardRow =
      EdgeInsets.symmetric(horizontal: lg, vertical: md);

  /// Side padding of a switch row in a card, whose height the tile sets.
  static const EdgeInsets cardRowSide = EdgeInsets.symmetric(horizontal: lg);

  /// Padding of a scrolling form screen.
  static const EdgeInsets form = EdgeInsets.fromLTRB(xl, sm, xl, xxxl);

  /// Padding of the actions pinned below a scrolling screen.
  static const EdgeInsets pinnedActions =
      EdgeInsets.fromLTRB(xl, sm, xl, xxxl - 4);

  /// Padding of the content of a bottom sheet.
  static const EdgeInsets sheet = EdgeInsets.fromLTRB(xl, sm, xl, xxxl - 4);

  /// Padding of a list tab (Medications, History, ...).
  static const EdgeInsets screen = EdgeInsets.fromLTRB(lg, sm, lg, xxl);

  /// Padding of the header of Today and Family.
  static const EdgeInsets tabHeader = EdgeInsets.fromLTRB(lg, xxl, lg, xxl);

  /// Gap between the cards of a list (Today, Family).
  static const double listGap = md;

  /// Gap between chips of a choice group (spacing and run spacing).
  static const double chips = sm;
}
