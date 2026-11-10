import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/error_snack_bar.dart';
import '../common/gap.dart';
import '../common/local_time.dart';
import '../common/pillpal_banner.dart';
import '../common/pillpal_card.dart';
import '../doses/dose_providers.dart';
import '../pharmacies/pharmacy_providers.dart';
import '../stock/stock_widgets.dart';
import 'today_state.dart';

/// Circular progress with "taken / total" in the middle (B2-README
/// `progressRing`): 56 across at any text scale, a `raised` track and a
/// `taken` arc. The label shrinks to fit, so it never leaves the ring.
/// Screen readers read «Принято N из M».
class ProgressRing extends StatelessWidget {
  /// Creates the ring.
  const ProgressRing({required this.done, required this.total, super.key});

  /// Completed doses.
  final int done;

  /// All doses.
  final int total;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = AppLocalizations.of(context);
    return Semantics(
      label: l10n.todayProgress(done, total),
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: PillPalSizes.progressRing,
        child: CustomPaint(
          painter: _RingPainter(
            fraction: total == 0 ? 0 : done / total,
            track: palette.raised,
            fill: palette.taken,
          ),
          child: Center(
            child: FittedBox(
              child: Padding(
                padding: const EdgeInsets.all(PillPalSpacing.sm),
                child: Text(
                  '$done/$total',
                  style: Theme.of(context).textTheme.numeral,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.fraction,
    required this.track,
    required this.fill,
  });

  static const double _stroke = 6;

  final double fraction;
  final Color track;
  final Color fill;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final arcRect = rect.deflate(_stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(arcRect, 0, 2 * math.pi, false, paint..color = track);
    if (fraction > 0) {
      canvas.drawArc(
        arcRect,
        -math.pi / 2,
        2 * math.pi * fraction,
        false,
        paint..color = fill,
      );
    }
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.fraction != fraction ||
      oldDelegate.track != track ||
      oldDelegate.fill != fill;
}

/// "Витамин D заканчивается: осталось на 5 дней · Аптеки · Пополнить".
class LowStockBanner extends ConsumerWidget {
  /// Creates the banner.
  const LowStockBanner({required this.item, super.key});

  /// The medication running low.
  final LowStockMedication item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final id = item.medication.id;
    final buttonStyle = TextButton.styleFrom(
      foregroundColor: palette.onActionSoft,
      minimumSize: Size.square(context.metrics.touchTarget),
    );
    return PillPalBanner(
      key: ValueKey('low-stock-$id'),
      icon: Icons.inventory_2_outlined,
      body: l10n.lowStock(item.medication.name ?? '', item.daysLeft),
      actionsAlignment: WrapAlignment.end,
      actions: [
        TextButton.icon(
          key: ValueKey('low-stock-pharmacies-$id'),
          style: buttonStyle,
          onPressed: () => openPharmacies(context, ref),
          icon: const Icon(Icons.location_on_outlined),
          label: Text(l10n.pharmacies),
        ),
        TextButton.icon(
          key: ValueKey('low-stock-refill-$id'),
          style: buttonStyle,
          onPressed: () => showRefillDialog(context, ref, id),
          icon: const Icon(Icons.add_shopping_cart_outlined),
          label: Text(l10n.refillShort),
        ),
      ],
    );
  }
}

/// An as-needed medication with a "mark intake" button and an undo of the
/// latest intake; both disabled while a write for it is running.
class AsNeededTile extends ConsumerWidget {
  /// Creates the tile.
  const AsNeededTile({required this.item, super.key});

  /// The medication and today's intakes.
  final AsNeededMedication item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final last = item.lastAt;
    final medication = item.medication;
    final strength = medication.strengthText;
    final name = strength == null || strength.isEmpty
        ? medication.name ?? ''
        : '${medication.name ?? ''} $strength';
    // Stacked rather than side by side: in senior mode the button label
    // needs the full width.
    return PillPalCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(name, style: textTheme.rowTitle),
          Text(
            last == null
                ? l10n.asNeededNone
                : l10n.asNeededTaken(
                    item.intakesToday,
                    wallClockOf(last, item.displayZone).hhmm,
                  ),
            style: textTheme.bodySmall,
          ),
          const Gap.v(PillPalSpacing.sm),
          _AsNeededActions(
            medicationId: medication.id,
            name: name,
            lastEventId: item.lastEventId,
          ),
        ],
      ),
    );
  }
}

/// "Undo" of the latest intake and "mark intake".
class _AsNeededActions extends ConsumerWidget {
  const _AsNeededActions({
    required this.medicationId,
    required this.name,
    required this.lastEventId,
  });

  final String medicationId;
  final String name;
  final String? lastEventId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final busy = ref.watch(
      doseWritesInFlightProvider.select(
        (keys) => keys.contains(asNeededWriteKey(medicationId)),
      ),
    );
    final actions = ref.read(doseActionsProvider);
    final target = Size.square(context.metrics.touchTarget);
    final undoTarget = lastEventId;
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: PillPalSpacing.sm,
      runSpacing: PillPalSpacing.sm,
      children: [
        if (undoTarget != null)
          TextButton(
            key: ValueKey('as-needed-undo-$medicationId'),
            style: TextButton.styleFrom(minimumSize: target),
            onPressed: busy
                ? null
                : () => runShowingErrors(
                      context,
                      actions.undoAsNeeded(medicationId, undoTarget),
                    ),
            child: Text(
              l10n.undoShort,
              semanticsLabel: l10n.asNeededUndoLabel(name),
            ),
          ),
        OutlinedButton(
          key: ValueKey('as-needed-$medicationId'),
          style: OutlinedButton.styleFrom(
            minimumSize: target,
            padding: const EdgeInsets.symmetric(horizontal: PillPalSpacing.md),
          ),
          onPressed: busy
              ? null
              : () => runShowingErrors(
                    context,
                    actions.takeAsNeeded(medicationId),
                  ),
          child: Text(
            l10n.markIntake,
            textAlign: TextAlign.center,
            semanticsLabel: l10n.asNeededTakeLabel(name),
          ),
        ),
      ],
    );
  }
}
