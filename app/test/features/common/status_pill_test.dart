import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/features/common/status_kind.dart';
import 'package:pillpal/src/features/common/status_pill.dart';
import 'package:pillpal/src/features/doses/dose_status.dart';
import 'package:pillpal/src/theme/palette.dart';
import 'package:pillpal/src/theme/sizes.dart';

import '../../support/ui_matrix.dart';
import 'common_test_host.dart';

const _palettes = [
  PillPalPalette.light,
  PillPalPalette.lightSenior,
  PillPalPalette.dark,
  PillPalPalette.darkSenior,
];

/// The danger family: no status may draw with it. `onDanger` is left out: it
/// is white in light themes, like `onMissed`, and white is not red.
Set<Color> _dangerColors(PillPalPalette p) =>
    {p.danger, p.dangerSoft, p.onDangerSoft};

void main() {
  group('status mapping', () {
    test('every dose status maps to a kind', () {
      expect(StatusKind.fromDose(DoseStatus.taken), StatusKind.taken);
      expect(StatusKind.fromDose(DoseStatus.missed), StatusKind.missed);
      expect(StatusKind.fromDose(DoseStatus.pending), StatusKind.pending);
      expect(StatusKind.fromDose(DoseStatus.skipped), StatusKind.skipped);
    });

    test('colours follow the status pill table of B2-README section 3', () {
      for (final p in _palettes) {
        final taken = statusStyle(StatusKind.taken, p);
        expect(taken.background, p.takenSoft);
        expect(taken.foreground, p.onTakenSoft);
        final missed = statusStyle(StatusKind.missed, p);
        expect(missed.background, p.missedSoft);
        expect(missed.foreground, p.onMissedSoft);
        final due = statusStyle(StatusKind.due, p);
        expect(due.background, p.actionSoft);
        expect(due.foreground, p.onActionSoft);
        final skipped = statusStyle(StatusKind.skipped, p);
        expect(skipped.background, p.raised);
        expect(skipped.foreground, p.inkMuted);
        final pending = statusStyle(StatusKind.pending, p);
        expect(pending.background, isNull);
        expect(pending.foreground, p.inkMuted);
        expect(pending.outline, p.border);
        // Paused or archived: neutral, never pending's outline, never red.
        final inactive = statusStyle(StatusKind.inactive, p);
        expect(inactive.background, p.raised);
        expect(inactive.foreground, p.inkMuted);
        expect(inactive.outline, isNull);
        // Running low: the soft action pair, a box icon, never red or «due».
        final low = statusStyle(StatusKind.lowStock, p);
        expect(low.background, p.actionSoft);
        expect(low.foreground, p.onActionSoft);
        expect(low.icon, isNot(statusStyle(StatusKind.due, p).icon));
      }
    });

    test('missed is never red, solid or soft', () {
      for (final p in _palettes) {
        for (final solid in [false, true]) {
          final style = statusStyle(StatusKind.missed, p, solid: solid);
          expect(_dangerColors(p), isNot(contains(style.background)));
          expect(_dangerColors(p), isNot(contains(style.foreground)));
        }
      }
    });

    test('solid pairs exist only for taken and missed', () {
      const p = PillPalPalette.lightSenior;
      final taken = statusStyle(StatusKind.taken, p, solid: true);
      expect(taken.background, p.taken);
      expect(taken.foreground, p.onTaken);
      final missed = statusStyle(StatusKind.missed, p, solid: true);
      expect(missed.background, p.missed);
      expect(missed.foreground, p.onMissed);
      expect(
        statusStyle(StatusKind.due, p, solid: true).background,
        p.actionSoft,
      );
    });

    test('every kind has its own icon', () {
      final icons = {
        for (final kind in StatusKind.values)
          statusStyle(kind, PillPalPalette.light).icon,
      };
      expect(icons.length, StatusKind.values.length);
    });
  });

  group('StatusPill', () {
    const words = {
      StatusKind.taken: 'Taken',
      StatusKind.missed: 'Missed',
      StatusKind.pending: 'Waiting',
      StatusKind.skipped: 'Skipped',
      StatusKind.due: 'Due now',
      StatusKind.inactive: 'Inactive',
      StatusKind.lowStock: 'Running low',
    };

    testWidgets('shows icon and word of every status', (tester) async {
      for (final kind in StatusKind.values) {
        await pumpThemed(tester, StatusPill(kind));
        final style = statusStyle(kind, paletteOf());
        expect(find.text(words[kind]!), findsOneWidget, reason: '$kind');
        expect(find.byIcon(style.icon), findsOneWidget, reason: '$kind');
        final text = tester.widget<Text>(find.text(words[kind]!));
        expect(text.style?.color, style.foreground);
        final box = tester.widget<DecoratedBox>(
          find.descendant(
            of: find.byType(StatusPill),
            matching: find.byType(DecoratedBox),
          ),
        );
        final shape = box.decoration as ShapeDecoration;
        expect(shape.color, style.background);
        expect(shape.shape, isA<StadiumBorder>());
      }
    });

    testWidgets('is 28 high at the normal text scale', (tester) async {
      await pumpThemed(tester, const StatusPill(StatusKind.taken));
      expect(
        tester.getSize(find.byType(StatusPill)).height,
        PillPalSizes.statusPill,
      );
    });

    testWidgets('the icon stays at the top when the word wraps',
        (tester) async {
      await pumpThemed(
        tester,
        const SizedBox(width: 140, child: StatusPill(StatusKind.skipped)),
        locale: const Locale('ru'),
        scale: 2,
      );
      final pill = tester.getRect(find.byType(StatusPill));
      final icon = tester.getRect(find.byIcon(Icons.skip_next_outlined));
      expect(icon.center.dy, lessThan(pill.top + pill.height / 2));
    });

    testWidgets('forwards its key', (tester) async {
      const key = Key('dose-status-s1/2026-11-10T08:00');
      await pumpThemed(tester, const StatusPill(StatusKind.missed, key: key));
      expect(tester.widget(find.byKey(key)), isA<StatusPill>());
    });

    testWidgets('status is announced as the word, not the icon',
        (tester) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(tester, const StatusPill(StatusKind.missed));
      expect(find.bySemanticsLabel('Missed'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('the word comes from the l10n of the locale', (tester) async {
      await pumpThemed(
        tester,
        const StatusPill(StatusKind.skipped),
        locale: const Locale('ru'),
      );
      final l10n = await AppLocalizations.delegate.load(const Locale('ru'));
      expect(find.text(l10n.statusSkipped), findsOneWidget);
    });

    testWidgets('every status in the whole matrix', (tester) async {
      await pumpUiMatrix(
        tester,
        (context) => Padding(
          padding: const EdgeInsets.all(8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final kind in StatusKind.values) StatusPill(kind),
            ],
          ),
        ),
        expectTouchTargets: true,
        expectContrast: true,
      );
    });
  });
}
