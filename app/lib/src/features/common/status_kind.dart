import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/palette.dart';
import '../doses/dose_status.dart';

/// What a status component shows: the five looks of B2-README section 3
/// (`statusPill`). [due] is the dose that is due right now, which has no
/// [DoseStatus] of its own.
enum StatusKind {
  /// Marked as taken.
  taken,

  /// Not marked and past the grace period; calm iris, never red.
  missed,

  /// Not marked yet.
  pending,

  /// Deliberately skipped.
  skipped,

  /// Due now (the «Сейчас» dose).
  due;

  /// The look of a dose status.
  static StatusKind fromDose(DoseStatus status) => switch (status) {
        DoseStatus.taken => StatusKind.taken,
        DoseStatus.missed => StatusKind.missed,
        DoseStatus.pending => StatusKind.pending,
        DoseStatus.skipped => StatusKind.skipped,
      };
}

/// Colours and icon of one [StatusKind] in one palette.
@immutable
class StatusStyle {
  /// Creates a style.
  const StatusStyle({
    required this.foreground,
    required this.icon,
    this.background,
    this.outline,
  });

  /// Fill; null draws no fill (the pending pill is an outline only).
  final Color? background;

  /// Icon and word.
  final Color foreground;

  /// Colour of the 1.5 px ring, when there is one.
  final Color? outline;

  /// The icon that carries the status next to its word.
  final IconData icon;
}

/// The style of [kind]. A status is always an icon plus a word; colour only
/// supports it. [solid] (senior mode) draws taken and missed with the strong
/// `taken` / `missed` pair instead of the soft one.
StatusStyle statusStyle(
  StatusKind kind,
  PillPalPalette palette, {
  bool solid = false,
}) {
  switch (kind) {
    case StatusKind.taken:
      return StatusStyle(
        background: solid ? palette.taken : palette.takenSoft,
        foreground: solid ? palette.onTaken : palette.onTakenSoft,
        icon: Icons.check,
      );
    case StatusKind.missed:
      return StatusStyle(
        background: solid ? palette.missed : palette.missedSoft,
        foreground: solid ? palette.onMissed : palette.onMissedSoft,
        icon: Icons.history,
      );
    case StatusKind.pending:
      return StatusStyle(
        foreground: palette.inkMuted,
        outline: palette.border,
        icon: Icons.circle_outlined,
      );
    case StatusKind.skipped:
      return StatusStyle(
        background: palette.raised,
        foreground: palette.inkMuted,
        icon: Icons.skip_next_outlined,
      );
    case StatusKind.due:
      return StatusStyle(
        background: palette.actionSoft,
        foreground: palette.onActionSoft,
        icon: Icons.schedule,
      );
  }
}

/// The word of [kind] in the language of [l10n].
String statusWord(AppLocalizations l10n, StatusKind kind) => switch (kind) {
      StatusKind.taken => l10n.statusTaken,
      StatusKind.missed => l10n.statusMissed,
      StatusKind.pending => l10n.statusPending,
      StatusKind.skipped => l10n.statusSkipped,
      StatusKind.due => l10n.statusDue,
    };
