import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/theme/app_theme.dart';
import 'package:pillpal/src/theme/palette.dart';

/// WCAG 2.x contrast ratio of two opaque colours.
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

typedef _Pick = Color Function(PillPalPalette p);

/// One foreground/background pair of docs/design/b2/README.md section 4.
/// [expected] is the documented ratio per theme: light, dark, light senior,
/// dark senior. [ui] marks a boundary pair (>= 3), otherwise text.
class _Pair {
  const _Pair(this.name, this.fg, this.bg, this.expected, {this.ui = false});

  final String name;
  final _Pick fg;
  final _Pick bg;
  final List<double> expected;
  final bool ui;
}

final _palettes = <(String, PillPalPalette, bool)>[
  ('light', PillPalPalette.light, false),
  ('dark', PillPalPalette.dark, false),
  ('lightSenior', PillPalPalette.lightSenior, true),
  ('darkSenior', PillPalPalette.darkSenior, true),
];

final _pairs = <_Pair>[
  _Pair('ink/bg', (p) => p.ink, (p) => p.background,
      [15.47, 12.97, 15.47, 13.76]),
  _Pair('ink/surface', (p) => p.ink, (p) => p.surface,
      [16.85, 10.89, 16.85, 11.56]),
  _Pair(
      'ink/raised', (p) => p.ink, (p) => p.raised, [14.29, 8.98, 14.29, 9.53]),
  _Pair('inkMuted/bg', (p) => p.inkMuted, (p) => p.background,
      [6.21, 7.30, 8.84, 10.78]),
  _Pair('inkMuted/surface', (p) => p.inkMuted, (p) => p.surface,
      [6.77, 6.13, 9.63, 9.06]),
  _Pair('inkMuted/raised', (p) => p.inkMuted, (p) => p.raised,
      [5.74, 5.06, 8.16, 7.47]),
  _Pair('action/bg', (p) => p.action, (p) => p.background,
      [5.88, 7.63, 7.79, 9.12]),
  _Pair('action/surface', (p) => p.action, (p) => p.surface,
      [6.41, 6.40, 8.48, 7.66]),
  _Pair('onAction/action', (p) => p.onAction, (p) => p.action,
      [6.41, 8.33, 8.48, 9.95]),
  _Pair('onActionSoft/actionSoft', (p) => p.onActionSoft, (p) => p.actionSoft,
      [8.58, 7.75, 10.00, 8.33]),
  _Pair('taken/bg', (p) => p.taken, (p) => p.background,
      [5.88, 7.63, 7.79, 9.12]),
  _Pair('taken/surface', (p) => p.taken, (p) => p.surface,
      [6.41, 6.40, 8.48, 7.66]),
  _Pair('onTaken/taken', (p) => p.onTaken, (p) => p.taken,
      [6.41, 8.33, 8.48, 9.95]),
  _Pair('onTakenSoft/takenSoft', (p) => p.onTakenSoft, (p) => p.takenSoft,
      [7.79, 7.30, 9.07, 7.75]),
  _Pair('ink/takenSoft', (p) => p.ink, (p) => p.takenSoft,
      [12.89, 7.93, 12.89, 8.41]),
  _Pair('missed/bg', (p) => p.missed, (p) => p.background,
      [6.39, 6.92, 8.35, 8.72]),
  _Pair('missed/surface', (p) => p.missed, (p) => p.surface,
      [6.96, 5.81, 9.09, 7.33]),
  _Pair('onMissed/missed', (p) => p.onMissed, (p) => p.missed,
      [6.96, 7.58, 9.09, 9.56]),
  _Pair('onMissedSoft/missedSoft', (p) => p.onMissedSoft, (p) => p.missedSoft,
      [8.57, 8.04, 10.03, 8.78]),
  _Pair('danger/bg', (p) => p.danger, (p) => p.background,
      [5.46, 6.69, 7.56, 8.83]),
  _Pair('danger/surface', (p) => p.danger, (p) => p.surface,
      [5.95, 5.62, 8.23, 7.42]),
  _Pair('onDanger/danger', (p) => p.onDanger, (p) => p.danger,
      [5.95, 7.76, 8.23, 10.24]),
  _Pair('onDangerSoft/dangerSoft', (p) => p.onDangerSoft, (p) => p.dangerSoft,
      [7.78, 9.07, 9.10, 9.67]),
  _Pair(
      'onHero/hero', (p) => p.onHero, (p) => p.hero, [6.41, 8.73, 8.48, 9.26]),
  _Pair('onHeroAction/heroAction', (p) => p.onHeroAction, (p) => p.heroAction,
      [6.41, 8.33, 8.48, 9.95]),
  _Pair('ink/actionSoft', (p) => p.ink, (p) => p.actionSoft,
      [14.21, 8.73, 14.21, 9.26]),
  _Pair('inkMuted/actionSoft', (p) => p.inkMuted, (p) => p.actionSoft,
      [5.71, 4.91, 8.12, 7.26]),
  _Pair('onActionSoft/raised', (p) => p.onActionSoft, (p) => p.raised,
      [8.63, 7.97, 10.06, 8.57]),
  _Pair('outline/surface', (p) => p.outline, (p) => p.surface,
      [4.34, 4.30, 6.77, 6.13],
      ui: true),
  _Pair('outline/bg', (p) => p.outline, (p) => p.background,
      [3.99, 5.12, 6.21, 7.30],
      ui: true),
  _Pair('action/surface (ui)', (p) => p.action, (p) => p.surface,
      [6.41, 6.40, 8.48, 7.66],
      ui: true),
  _Pair('taken/takenSoft', (p) => p.taken, (p) => p.takenSoft,
      [4.90, 4.66, 6.49, 5.57],
      ui: true),
];

void main() {
  test('every pair of the spec table reproduces its documented ratio', () {
    for (final pair in _pairs) {
      for (var i = 0; i < _palettes.length; i++) {
        final (name, palette, _) = _palettes[i];
        final ratio = _contrast(pair.fg(palette), pair.bg(palette));
        expect(
          ratio,
          closeTo(pair.expected[i], 0.02),
          reason: '$name ${pair.name}',
        );
      }
    }
  });

  test('text pairs reach 4.5:1 normal and 7:1 senior, no exceptions', () {
    for (final (name, palette, senior) in _palettes) {
      final minimum = senior ? 7.0 : 4.5;
      for (final pair in _pairs.where((p) => !p.ui)) {
        expect(
          _contrast(pair.fg(palette), pair.bg(palette)),
          greaterThanOrEqualTo(minimum),
          reason: '$name ${pair.name}',
        );
      }
    }
  });

  test('UI boundaries reach 3:1 in every palette', () {
    for (final (name, palette, _) in _palettes) {
      for (final pair in _pairs.where((p) => p.ui)) {
        expect(
          _contrast(pair.fg(palette), pair.bg(palette)),
          greaterThanOrEqualTo(3),
          reason: '$name ${pair.name}',
        );
      }
    }
  });

  test('missed is its own indigo, never the danger red', () {
    for (final (name, p, _) in _palettes) {
      expect(p.missed, isNot(p.danger), reason: name);
      expect(p.missedSoft, isNot(p.dangerSoft), reason: name);
      expect(p.onMissedSoft, isNot(p.onDangerSoft), reason: name);
      expect(p.missed.b, greaterThan(p.missed.r), reason: '$name missed');
      expect(p.missedSoft.b, greaterThan(p.missedSoft.r),
          reason: '$name missedSoft');
      expect(p.danger.r, greaterThan(p.danger.b), reason: '$name danger');
    }
  });

  test('disabled buttons stay readable (inkMuted on raised)', () {
    for (final (name, p, senior) in _palettes) {
      expect(
        _contrast(p.inkMuted, p.raised),
        greaterThanOrEqualTo(senior ? 7 : 4.5),
        reason: name,
      );
    }
  });

  test('the theme colour scheme keeps the same pairs', () {
    for (final brightness in Brightness.values) {
      for (final senior in [false, true]) {
        final theme = buildPillPalTheme(brightness: brightness, senior: senior);
        final s = theme.colorScheme;
        final minimum = senior ? 7.0 : 4.5;
        final label = '$brightness senior=$senior';
        expect(_contrast(s.onPrimary, s.primary), greaterThanOrEqualTo(minimum),
            reason: '$label primary');
        expect(
          _contrast(s.onSecondaryContainer, s.secondaryContainer),
          greaterThanOrEqualTo(minimum),
          reason: '$label secondaryContainer',
        );
        expect(_contrast(s.onError, s.error), greaterThanOrEqualTo(minimum),
            reason: '$label error');
        expect(_contrast(s.onSurface, s.surface), greaterThanOrEqualTo(minimum),
            reason: '$label surface');
        expect(_contrast(s.outline, s.surface), greaterThanOrEqualTo(3),
            reason: '$label outline');
      }
    }
  });
}
