import 'package:flutter/material.dart';

/// Colour tokens of the «Абрикос» design system (docs/design.md).
///
/// Exposed as a [ThemeExtension] so widgets read semantic colours
/// (`taken`, `missed`, ...) instead of hard-coded values.
@immutable
class PillPalPalette extends ThemeExtension<PillPalPalette> {
  /// Creates a palette.
  const PillPalPalette({
    required this.background,
    required this.surface,
    required this.border,
    required this.ink,
    required this.inkMuted,
    required this.action,
    required this.onAction,
    required this.actionSoft,
    required this.onActionSoft,
    required this.taken,
    required this.onTaken,
    required this.missed,
    required this.onMissed,
  });

  /// Light palette.
  static const PillPalPalette light = PillPalPalette(
    background: Color(0xFFFFF7F0),
    surface: Color(0xFFFFFFFF),
    border: Color(0xFFEADBCF),
    ink: Color(0xFF2B2320),
    inkMuted: Color(0xFF6B5D57),
    action: Color(0xFFC2531E),
    onAction: Color(0xFFFFFFFF),
    actionSoft: Color(0xFFFCE6D6),
    onActionSoft: Color(0xFF5A2A10),
    taken: Color(0xFF4F7A63),
    onTaken: Color(0xFFFFFFFF),
    missed: Color(0xFF2F5D8A),
    onMissed: Color(0xFFFFFFFF),
  );

  /// Dark palette.
  static const PillPalPalette dark = PillPalPalette(
    background: Color(0xFF1C1715),
    surface: Color(0xFF2A2320),
    border: Color(0xFF3A302B),
    ink: Color(0xFFF6EDE6),
    inkMuted: Color(0xFFD9C8BC),
    action: Color(0xFFF4A57A),
    onAction: Color(0xFF1C1715),
    actionSoft: Color(0xFF3A2A22),
    onActionSoft: Color(0xFFFFD2B8),
    taken: Color(0xFF7FB79A),
    onTaken: Color(0xFF1C1715),
    missed: Color(0xFF8DB4DE),
    onMissed: Color(0xFF1C1715),
  );

  /// Screen background.
  final Color background;

  /// Cards and inputs.
  final Color surface;

  /// Dividers and outlines.
  final Color border;

  /// Primary text.
  final Color ink;

  /// Secondary text.
  final Color inkMuted;

  /// Main action ("Taken").
  final Color action;

  /// Content on [action].
  final Color onAction;

  /// Soft highlight (stock, invites).
  final Color actionSoft;

  /// Content on [actionSoft].
  final Color onActionSoft;

  /// Dose taken.
  final Color taken;

  /// Content on [taken].
  final Color onTaken;

  /// Dose missed.
  final Color missed;

  /// Content on [missed].
  final Color onMissed;

  @override
  PillPalPalette copyWith({
    Color? background,
    Color? surface,
    Color? border,
    Color? ink,
    Color? inkMuted,
    Color? action,
    Color? onAction,
    Color? actionSoft,
    Color? onActionSoft,
    Color? taken,
    Color? onTaken,
    Color? missed,
    Color? onMissed,
  }) {
    return PillPalPalette(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      border: border ?? this.border,
      ink: ink ?? this.ink,
      inkMuted: inkMuted ?? this.inkMuted,
      action: action ?? this.action,
      onAction: onAction ?? this.onAction,
      actionSoft: actionSoft ?? this.actionSoft,
      onActionSoft: onActionSoft ?? this.onActionSoft,
      taken: taken ?? this.taken,
      onTaken: onTaken ?? this.onTaken,
      missed: missed ?? this.missed,
      onMissed: onMissed ?? this.onMissed,
    );
  }

  @override
  PillPalPalette lerp(ThemeExtension<PillPalPalette>? other, double t) {
    if (other is! PillPalPalette) {
      return this;
    }
    Color mix(Color a, Color b) => Color.lerp(a, b, t) ?? a;
    return PillPalPalette(
      background: mix(background, other.background),
      surface: mix(surface, other.surface),
      border: mix(border, other.border),
      ink: mix(ink, other.ink),
      inkMuted: mix(inkMuted, other.inkMuted),
      action: mix(action, other.action),
      onAction: mix(onAction, other.onAction),
      actionSoft: mix(actionSoft, other.actionSoft),
      onActionSoft: mix(onActionSoft, other.onActionSoft),
      taken: mix(taken, other.taken),
      onTaken: mix(onTaken, other.onTaken),
      missed: mix(missed, other.missed),
      onMissed: mix(onMissed, other.onMissed),
    );
  }
}

/// Shortcut: `context.palette`.
extension PillPalPaletteContext on BuildContext {
  /// The active [PillPalPalette].
  PillPalPalette get palette =>
      Theme.of(this).extension<PillPalPalette>() ?? PillPalPalette.light;
}
