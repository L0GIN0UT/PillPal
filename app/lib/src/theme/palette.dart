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
    required this.takenSoft,
    required this.missed,
    required this.info,
    required this.onMissed,
    required this.danger,
    required this.onDanger,
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
    takenSoft: Color(0xFFB9D3C3),
    missed: Color(0xFF2F5D8A),
    info: Color(0xFF2F5D8A),
    onMissed: Color(0xFFFFFFFF),
    danger: Color(0xFF9E2B25),
    onDanger: Color(0xFFFFFFFF),
  );

  /// Light palette for senior mode: text and state colours >= 7:1 (D2 in
  /// docs/ui-pass-plan.md). Darker shades of the same hues.
  static const PillPalPalette lightSenior = PillPalPalette(
    background: Color(0xFFFFF7F0),
    surface: Color(0xFFFFFFFF),
    border: Color(0xFFEADBCF),
    ink: Color(0xFF2B2320),
    inkMuted: Color(0xFF574A44),
    action: Color(0xFF8F3A12),
    onAction: Color(0xFFFFFFFF),
    actionSoft: Color(0xFFFCE6D6),
    onActionSoft: Color(0xFF5A2A10),
    taken: Color(0xFF2F5C45),
    onTaken: Color(0xFFFFFFFF),
    takenSoft: Color(0xFFB9D3C3),
    missed: Color(0xFF285280),
    info: Color(0xFF285280),
    onMissed: Color(0xFFFFFFFF),
    danger: Color(0xFF9E2B25),
    onDanger: Color(0xFFFFFFFF),
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
    takenSoft: Color(0xFF34503F),
    missed: Color(0xFF8DB4DE),
    info: Color(0xFF8DB4DE),
    onMissed: Color(0xFF1C1715),
    danger: Color(0xFFF28B7D),
    onDanger: Color(0xFF1C1715),
  );

  /// Dark palette for senior mode: the dark palette already passes 7:1 except
  /// `taken` and `danger` on `surface`, which get lighter shades.
  static const PillPalPalette darkSenior = PillPalPalette(
    background: Color(0xFF1C1715),
    surface: Color(0xFF2A2320),
    border: Color(0xFF3A302B),
    ink: Color(0xFFF6EDE6),
    inkMuted: Color(0xFFD9C8BC),
    action: Color(0xFFF4A57A),
    onAction: Color(0xFF1C1715),
    actionSoft: Color(0xFF3A2A22),
    onActionSoft: Color(0xFFFFD2B8),
    taken: Color(0xFF8CC2A5),
    onTaken: Color(0xFF1C1715),
    takenSoft: Color(0xFF34503F),
    missed: Color(0xFF8DB4DE),
    info: Color(0xFF8DB4DE),
    onMissed: Color(0xFF1C1715),
    danger: Color(0xFFF5A08F),
    onDanger: Color(0xFF1C1715),
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

  /// Soft sage of a day with some doses taken (D6); text on it is [ink].
  final Color takenSoft;

  /// Dose missed.
  final Color missed;

  /// Information notes (blue like [missed], but a separate token: a note is
  /// not a missed dose).
  final Color info;

  /// Content on [missed].
  final Color onMissed;

  /// Destructive actions and blocking problems (never "missed").
  final Color danger;

  /// Content on [danger].
  final Color onDanger;

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
    Color? takenSoft,
    Color? missed,
    Color? info,
    Color? onMissed,
    Color? danger,
    Color? onDanger,
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
      takenSoft: takenSoft ?? this.takenSoft,
      missed: missed ?? this.missed,
      info: info ?? this.info,
      onMissed: onMissed ?? this.onMissed,
      danger: danger ?? this.danger,
      onDanger: onDanger ?? this.onDanger,
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
      takenSoft: mix(takenSoft, other.takenSoft),
      missed: mix(missed, other.missed),
      info: mix(info, other.info),
      onMissed: mix(onMissed, other.onMissed),
      danger: mix(danger, other.danger),
      onDanger: mix(onDanger, other.onDanger),
    );
  }
}

/// Shortcut: `context.palette`.
extension PillPalPaletteContext on BuildContext {
  /// The active [PillPalPalette].
  PillPalPalette get palette =>
      Theme.of(this).extension<PillPalPalette>() ?? PillPalPalette.light;
}
