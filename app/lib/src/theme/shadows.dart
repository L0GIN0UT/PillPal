import 'package:flutter/widgets.dart';

/// Elevation of the «Забота» system (B2-README section 6). Light themes draw
/// these shadows; dark themes have none and step up in lightness instead, so
/// callers pass the level through [forBrightness].
abstract final class PillPalShadows {
  /// Cards and the selected segment: two soft layers.
  static const List<BoxShadow> level1 = [
    BoxShadow(
      offset: Offset(0, 1),
      blurRadius: 2,
      color: Color(0x0F102824),
    ),
    BoxShadow(
      offset: Offset(0, 6),
      blurRadius: 16,
      color: Color(0x0F102824),
    ),
  ];

  /// FAB, sheets, dialogs and the raised QR card.
  static const List<BoxShadow> level2 = [
    BoxShadow(
      offset: Offset(0, 2),
      blurRadius: 4,
      color: Color(0x14102824),
    ),
    BoxShadow(
      offset: Offset(0, 12),
      blurRadius: 28,
      color: Color(0x24102824),
    ),
  ];

  /// The top edge of the bottom navigation bar (dark: a 1 px `border` line,
  /// drawn by the bar).
  static const List<BoxShadow> nav = [
    BoxShadow(
      offset: Offset(0, -6),
      blurRadius: 24,
      color: Color(0x14102824),
    ),
  ];

  /// [light] in a light theme, no shadow in a dark one.
  static List<BoxShadow> forBrightness(
    Brightness brightness,
    List<BoxShadow> light,
  ) =>
      brightness == Brightness.dark ? const [] : light;
}
