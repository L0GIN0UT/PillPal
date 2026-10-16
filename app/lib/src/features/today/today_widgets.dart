import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../common/error_snack_bar.dart';
import '../common/local_time.dart';
import '../doses/dose_providers.dart';
import 'dose_tile.dart';
import 'today_state.dart';

/// Progress ring with "taken / total" and the next dose time.
class TodaySummaryCard extends ConsumerWidget {
  /// Creates the card.
  const TodaySummaryCard({required this.state, super.key});

  /// Today's state.
  final TodayState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final total = state.doses.length;
    final taken = state.takenCount;
    final next = state.nextDose;
    final tz = ref.watch(deviceTimeZoneProvider);
    return Card(
      key: const Key('today-summary'),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(24),
        side: BorderSide(color: context.palette.border),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: Row(
          children: [
            ProgressRing(done: taken, total: total),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    total > 0 && taken == total
                        ? l10n.todayAllTaken
                        : l10n.todayProgress(taken, total),
                    style: textTheme.titleMedium,
                  ),
                  if (next != null)
                    Text(
                      l10n.todayNextAt(doseTime(next, tz)),
                      style: textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Circular progress with the "N/M" label in the middle.
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
        dimension: 60,
        child: CustomPaint(
          painter: _RingPainter(
            fraction: total == 0 ? 0 : done / total,
            track: palette.border,
            fill: palette.taken,
          ),
          child: Center(
            child: FittedBox(
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Text(
                  '$done/$total',
                  style: Theme.of(context).textTheme.titleSmall,
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

  static const double _stroke = 7;

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

/// "Витамин D заканчивается: осталось на 5 дней · Аптеки".
class LowStockBanner extends StatelessWidget {
  /// Creates the banner.
  const LowStockBanner({required this.item, super.key});

  /// The medication running low.
  final LowStockMedication item;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    return Container(
      key: ValueKey('low-stock-${item.medication.id}'),
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      decoration: BoxDecoration(
        color: palette.actionSoft,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          Icon(Icons.location_on_outlined, color: palette.onActionSoft),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              l10n.lowStock(item.medication.name, item.daysLeft),
              style: TextStyle(color: palette.onActionSoft),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: palette.onActionSoft,
              minimumSize: const Size(48, 48),
            ),
            // TODO(2.4): open the maps app with a "pharmacy" search
            // (docs/phase2-plan.md, milestone 2.4).
            onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l10n.pharmaciesSoon)),
            ),
            child: Text(l10n.pharmacies),
          ),
        ],
      ),
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
    final tz = ref.watch(deviceTimeZoneProvider);
    final last = item.lastAt;
    final medication = item.medication;
    final strength = medication.strengthText;
    final name = strength == null || strength.isEmpty
        ? medication.name
        : '${medication.name} $strength';
    // Stacked rather than side by side: in senior mode the button label
    // needs the full width.
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: textTheme.titleMedium),
            Text(
              last == null
                  ? l10n.asNeededNone
                  : l10n.asNeededTaken(
                      item.intakesToday,
                      wallClockOf(last, tz).hhmm,
                    ),
              style: textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            _AsNeededActions(
              medicationId: medication.id,
              name: name,
              lastEventId: item.lastEventId,
            ),
          ],
        ),
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
      spacing: 8,
      runSpacing: 8,
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
            padding: const EdgeInsets.symmetric(horizontal: 12),
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
