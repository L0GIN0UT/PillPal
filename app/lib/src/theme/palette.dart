import 'package:flutter/material.dart';

/// Colour tokens of the «Забота» design system (docs/design.md).
///
/// Exposed as a [ThemeExtension] so widgets read semantic colours
/// (`taken`, `missed`, ...) instead of hard-coded values. Every value is the
/// exact one of docs/design/b2/README.md sections 2 and 3, checked pair by
/// pair in `test/theme_contrast_test.dart`.
@immutable
class PillPalPalette extends ThemeExtension<PillPalPalette> {
  /// Creates a palette.
  const PillPalPalette({
    required this.background,
    required this.surface,
    required this.raised,
    required this.border,
    required this.outline,
    required this.ink,
    required this.inkMuted,
    required this.action,
    required this.onAction,
    required this.actionSoft,
    required this.onActionSoft,
    required this.selected,
    required this.onSelected,
    required this.taken,
    required this.onTaken,
    required this.takenSoft,
    required this.onTakenSoft,
    required this.missed,
    required this.onMissed,
    required this.missedSoft,
    required this.onMissedSoft,
    required this.danger,
    required this.onDanger,
    required this.dangerSoft,
    required this.onDangerSoft,
    required this.scrim,
    required this.hero,
    required this.onHero,
    required this.heroAction,
    required this.onHeroAction,
  });

  /// Light palette.
  static const PillPalPalette light = PillPalPalette(
    background: Color(0xFFF2F6F5),
    surface: Color(0xFFFFFFFF),
    raised: Color(0xFFE6EEEC),
    border: Color(0xFFD3DEDB),
    outline: Color(0xFF6B7D79),
    ink: Color(0xFF10201D),
    inkMuted: Color(0xFF4D5F5B),
    action: Color(0xFF0C6B5D),
    onAction: Color(0xFFFFFFFF),
    actionSoft: Color(0xFFDCF0EB),
    onActionSoft: Color(0xFF074A40),
    selected: Color(0xFFDCF0EB),
    onSelected: Color(0xFF074A40),
    taken: Color(0xFF0C6B5D),
    onTaken: Color(0xFFFFFFFF),
    takenSoft: Color(0xFFC8E8DF),
    onTakenSoft: Color(0xFF074A40),
    missed: Color(0xFF4652A6),
    onMissed: Color(0xFFFFFFFF),
    missedSoft: Color(0xFFE4E7F8),
    onMissedSoft: Color(0xFF2E3880),
    danger: Color(0xFFBD2A2A),
    onDanger: Color(0xFFFFFFFF),
    dangerSoft: Color(0xFFFBE4E2),
    onDangerSoft: Color(0xFF871D1D),
    scrim: Color(0xFF10201D),
    hero: Color(0xFF0C6B5D),
    onHero: Color(0xFFFFFFFF),
    heroAction: Color(0xFFFFFFFF),
    onHeroAction: Color(0xFF0C6B5D),
  );

  /// Light palette for senior mode: text >= 7:1.
  static const PillPalPalette lightSenior = PillPalPalette(
    background: Color(0xFFF2F6F5),
    surface: Color(0xFFFFFFFF),
    raised: Color(0xFFE6EEEC),
    border: Color(0xFFAFC2BD),
    outline: Color(0xFF4D5F5B),
    ink: Color(0xFF10201D),
    inkMuted: Color(0xFF384845),
    action: Color(0xFF08574B),
    onAction: Color(0xFFFFFFFF),
    actionSoft: Color(0xFFDCF0EB),
    onActionSoft: Color(0xFF053F36),
    selected: Color(0xFFDCF0EB),
    onSelected: Color(0xFF053F36),
    taken: Color(0xFF08574B),
    onTaken: Color(0xFFFFFFFF),
    takenSoft: Color(0xFFC8E8DF),
    onTakenSoft: Color(0xFF053F36),
    missed: Color(0xFF36418F),
    onMissed: Color(0xFFFFFFFF),
    missedSoft: Color(0xFFE4E7F8),
    onMissedSoft: Color(0xFF252E70),
    danger: Color(0xFF981F1F),
    onDanger: Color(0xFFFFFFFF),
    dangerSoft: Color(0xFFFBE4E2),
    onDangerSoft: Color(0xFF751818),
    scrim: Color(0xFF10201D),
    hero: Color(0xFF08574B),
    onHero: Color(0xFFFFFFFF),
    heroAction: Color(0xFFFFFFFF),
    onHeroAction: Color(0xFF08574B),
  );

  /// Dark palette: green-grey, not black.
  static const PillPalPalette dark = PillPalPalette(
    background: Color(0xFF202A28),
    surface: Color(0xFF2A3734),
    raised: Color(0xFF354441),
    border: Color(0xFF455754),
    outline: Color(0xFF8A9C98),
    ink: Color(0xFFEAF2F0),
    inkMuted: Color(0xFFA9BAB6),
    action: Color(0xFF5BCDB6),
    onAction: Color(0xFF05261F),
    actionSoft: Color(0xFF1F4A41),
    onActionSoft: Color(0xFFBDEDE2),
    selected: Color(0xFF5BCDB6),
    onSelected: Color(0xFF05261F),
    taken: Color(0xFF5BCDB6),
    onTaken: Color(0xFF05261F),
    takenSoft: Color(0xFF285047),
    onTakenSoft: Color(0xFFC6F0E6),
    missed: Color(0xFFA3ADF5),
    onMissed: Color(0xFF161C4A),
    missedSoft: Color(0xFF323A5E),
    onMissedSoft: Color(0xFFD5DAFF),
    danger: Color(0xFFFF8F86),
    onDanger: Color(0xFF3A0A0A),
    dangerSoft: Color(0xFF4C2C2C),
    onDangerSoft: Color(0xFFFFD3CE),
    scrim: Color(0xFF0B1110),
    hero: Color(0xFF1F4A41),
    onHero: Color(0xFFEAF2F0),
    heroAction: Color(0xFF5BCDB6),
    onHeroAction: Color(0xFF05261F),
  );

  /// Dark palette for senior mode: text >= 7:1.
  static const PillPalPalette darkSenior = PillPalPalette(
    background: Color(0xFF202A28),
    surface: Color(0xFF2A3734),
    raised: Color(0xFF354441),
    border: Color(0xFF566B67),
    outline: Color(0xFFA9BAB6),
    ink: Color(0xFFF3F8F7),
    inkMuted: Color(0xFFD3DFDB),
    action: Color(0xFF7FDCC8),
    onAction: Color(0xFF05261F),
    actionSoft: Color(0xFF1F4A41),
    onActionSoft: Color(0xFFCDF3EA),
    selected: Color(0xFF7FDCC8),
    onSelected: Color(0xFF05261F),
    taken: Color(0xFF7FDCC8),
    onTaken: Color(0xFF05261F),
    takenSoft: Color(0xFF285047),
    onTakenSoft: Color(0xFFD3F5EC),
    missed: Color(0xFFBCC4FA),
    onMissed: Color(0xFF161C4A),
    missedSoft: Color(0xFF323A5E),
    onMissedSoft: Color(0xFFE0E4FF),
    danger: Color(0xFFFFB6B0),
    onDanger: Color(0xFF3A0A0A),
    dangerSoft: Color(0xFF4C2C2C),
    onDangerSoft: Color(0xFFFFDCD8),
    scrim: Color(0xFF0B1110),
    hero: Color(0xFF1F4A41),
    onHero: Color(0xFFF3F8F7),
    heroAction: Color(0xFF7FDCC8),
    onHeroAction: Color(0xFF05261F),
  );

  /// Screen background.
  final Color background;

  /// Cards, groups, fields, sheets and dialogs.
  final Color surface;

  /// Chips off, neutral banner, segmented track, avatar.
  final Color raised;

  /// Dividers, card hairlines, secondary button ring.
  final Color border;

  /// Boundary of fields, checkboxes and switches (>= 3:1).
  final Color outline;

  /// Primary text and icons.
  final Color ink;

  /// Secondary text, inactive navigation.
  final Color inkMuted;

  /// Primary button, links, focus, active switch.
  final Color action;

  /// Content on [action].
  final Color onAction;

  /// Tonal button, soft banner, due pill (not a selection: see [selected]).
  final Color actionSoft;

  /// Content on [actionSoft].
  final Color onActionSoft;

  /// Every selected state: the nav indicator, the selected profile chip,
  /// choice button and filter chip. The soft pair in light palettes; the
  /// solid [action] pair in dark ones, where `actionSoft` on `surface` is
  /// under 1.5:1 and the selection would disappear.
  final Color selected;

  /// Content on [selected].
  final Color onSelected;

  /// Dose taken (the same pine as [action], on purpose).
  final Color taken;

  /// Content on [taken].
  final Color onTaken;

  /// Taken pill and partially taken calendar day.
  final Color takenSoft;

  /// Text on [takenSoft].
  final Color onTakenSoft;

  /// Dose missed: calm iris, never red.
  final Color missed;

  /// Content on [missed].
  final Color onMissed;

  /// Missed pill.
  final Color missedSoft;

  /// Text on [missedSoft].
  final Color onMissedSoft;

  /// Destructive actions and blocking errors only.
  final Color danger;

  /// Content on [danger].
  final Color onDanger;

  /// Danger banner and destructive icon tile.
  final Color dangerSoft;

  /// Text on [dangerSoft].
  final Color onDangerSoft;

  /// Modal scrim colour, used at 48 % opacity.
  final Color scrim;

  /// Background of the «Сейчас» card.
  final Color hero;

  /// Text on [hero].
  final Color onHero;

  /// «Принял» inside the «Сейчас» card.
  final Color heroAction;

  /// Label of [heroAction].
  final Color onHeroAction;

  @override
  PillPalPalette copyWith({
    Color? background,
    Color? surface,
    Color? raised,
    Color? border,
    Color? outline,
    Color? ink,
    Color? inkMuted,
    Color? action,
    Color? onAction,
    Color? actionSoft,
    Color? onActionSoft,
    Color? selected,
    Color? onSelected,
    Color? taken,
    Color? onTaken,
    Color? takenSoft,
    Color? onTakenSoft,
    Color? missed,
    Color? onMissed,
    Color? missedSoft,
    Color? onMissedSoft,
    Color? danger,
    Color? onDanger,
    Color? dangerSoft,
    Color? onDangerSoft,
    Color? scrim,
    Color? hero,
    Color? onHero,
    Color? heroAction,
    Color? onHeroAction,
  }) {
    return PillPalPalette(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      raised: raised ?? this.raised,
      border: border ?? this.border,
      outline: outline ?? this.outline,
      ink: ink ?? this.ink,
      inkMuted: inkMuted ?? this.inkMuted,
      action: action ?? this.action,
      onAction: onAction ?? this.onAction,
      actionSoft: actionSoft ?? this.actionSoft,
      onActionSoft: onActionSoft ?? this.onActionSoft,
      selected: selected ?? this.selected,
      onSelected: onSelected ?? this.onSelected,
      taken: taken ?? this.taken,
      onTaken: onTaken ?? this.onTaken,
      takenSoft: takenSoft ?? this.takenSoft,
      onTakenSoft: onTakenSoft ?? this.onTakenSoft,
      missed: missed ?? this.missed,
      onMissed: onMissed ?? this.onMissed,
      missedSoft: missedSoft ?? this.missedSoft,
      onMissedSoft: onMissedSoft ?? this.onMissedSoft,
      danger: danger ?? this.danger,
      onDanger: onDanger ?? this.onDanger,
      dangerSoft: dangerSoft ?? this.dangerSoft,
      onDangerSoft: onDangerSoft ?? this.onDangerSoft,
      scrim: scrim ?? this.scrim,
      hero: hero ?? this.hero,
      onHero: onHero ?? this.onHero,
      heroAction: heroAction ?? this.heroAction,
      onHeroAction: onHeroAction ?? this.onHeroAction,
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
      raised: mix(raised, other.raised),
      border: mix(border, other.border),
      outline: mix(outline, other.outline),
      ink: mix(ink, other.ink),
      inkMuted: mix(inkMuted, other.inkMuted),
      action: mix(action, other.action),
      onAction: mix(onAction, other.onAction),
      actionSoft: mix(actionSoft, other.actionSoft),
      onActionSoft: mix(onActionSoft, other.onActionSoft),
      selected: mix(selected, other.selected),
      onSelected: mix(onSelected, other.onSelected),
      taken: mix(taken, other.taken),
      onTaken: mix(onTaken, other.onTaken),
      takenSoft: mix(takenSoft, other.takenSoft),
      onTakenSoft: mix(onTakenSoft, other.onTakenSoft),
      missed: mix(missed, other.missed),
      onMissed: mix(onMissed, other.onMissed),
      missedSoft: mix(missedSoft, other.missedSoft),
      onMissedSoft: mix(onMissedSoft, other.onMissedSoft),
      danger: mix(danger, other.danger),
      onDanger: mix(onDanger, other.onDanger),
      dangerSoft: mix(dangerSoft, other.dangerSoft),
      onDangerSoft: mix(onDangerSoft, other.onDangerSoft),
      scrim: mix(scrim, other.scrim),
      hero: mix(hero, other.hero),
      onHero: mix(onHero, other.onHero),
      heroAction: mix(heroAction, other.heroAction),
      onHeroAction: mix(onHeroAction, other.onHeroAction),
    );
  }
}

/// Shortcut: `context.palette`.
extension PillPalPaletteContext on BuildContext {
  /// The active [PillPalPalette].
  PillPalPalette get palette =>
      Theme.of(this).extension<PillPalPalette>() ?? PillPalPalette.light;
}
