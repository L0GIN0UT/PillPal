import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/repositories/dose_events_repository.dart';
import '../../theme/palette.dart';
import '../common/error_snack_bar.dart';
import '../common/local_time.dart';
import '../doses/dose_providers.dart';
import '../doses/dose_status.dart';
import '../doses/scheduled_doses.dart';
import 'dose_tile.dart';
import 'senior_cards.dart';
import 'today_state.dart';

/// A mark just made on the "now" card, shown with an undo before the card
/// moves on to the next dose.
typedef SeniorConfirmation = ({
  ScheduledDose dose,
  DoseEventType type,
  String eventId,
});

/// Senior-mode Today (mockup "TodaySenior"): one large card for the dose to
/// take now, then the day grouped by time.
///
/// After "take" or "skip" the card confirms the mark with an undo for
/// [DoseTiming.confirmation] before it shows the next dose, so a mistaken
/// tap is visible and reversible.
class SeniorTodayContent extends ConsumerStatefulWidget {
  /// Creates the content.
  const SeniorTodayContent({required this.state, super.key});

  /// Today's state.
  final TodayState state;

  @override
  ConsumerState<SeniorTodayContent> createState() => _SeniorTodayState();
}

class _SeniorTodayState extends ConsumerState<SeniorTodayContent> {
  SeniorConfirmation? _confirmation;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _mark(ScheduledDose dose, DoseEventType type) async {
    final actions = ref.read(doseActionsProvider);
    try {
      final id = type == DoseEventType.taken
          ? await actions.take(dose)
          : await actions.skip(dose);
      if (id == null || !mounted) {
        return;
      }
      _timer?.cancel();
      _timer = Timer(DoseTiming.confirmation, _clearConfirmation);
      setState(() => _confirmation = (dose: dose, type: type, eventId: id));
    } on Object {
      if (mounted) {
        showErrorSnackBar(context);
      }
    }
  }

  Future<void> _undo(SeniorConfirmation confirmation) async {
    _timer?.cancel();
    _clearConfirmation();
    try {
      await ref.read(doseActionsProvider).undoEvent(
            key: confirmation.dose.occurrence.key,
            eventId: confirmation.eventId,
          );
    } on Object {
      if (mounted) {
        showErrorSnackBar(context);
      }
    }
  }

  void _clearConfirmation() {
    if (mounted && _confirmation != null) {
      setState(() => _confirmation = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final confirmation = _confirmation;
    final current = confirmation == null ? state.currentDose : null;
    final tz = ref.watch(deviceTimeZoneProvider);
    final groups = <String, List<ScheduledDose>>{};
    for (final dose in state.doses) {
      final key = dose.occurrence.key;
      if (key == current?.occurrence.key ||
          key == confirmation?.dose.occurrence.key) {
        continue;
      }
      (groups[doseTime(dose, tz)] ??= <ScheduledDose>[]).add(dose);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (confirmation != null)
          SeniorConfirmationCard(
            confirmation: confirmation,
            onUndo: () => _undo(confirmation),
          )
        else if (current != null)
          SeniorNowCard(
            dose: current,
            due: !current.dueAt.isAfter(state.now),
            onTake: () => _mark(current, DoseEventType.taken),
            onSkip: () => _mark(current, DoseEventType.skipped),
          )
        else if (state.doses.isNotEmpty)
          const SeniorAllDoneCard(),
        for (final entry in groups.entries) ...[
          const SizedBox(height: 12),
          _TimeGroupRow(time: entry.key, doses: entry.value),
        ],
      ],
    );
  }
}

/// The doses of one time; a tap opens their take/skip/undo actions.
class _TimeGroupRow extends ConsumerWidget {
  const _TimeGroupRow({required this.time, required this.doses});

  final String time;
  final List<ScheduledDose> doses;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    final allTaken = doses.every((d) => d.status == DoseStatus.taken);
    final status = groupStatus(l10n, palette, doses);
    final names = doses.map(medicationTitle).join(', ');
    void open() {
      if (doses.length == 1) {
        unawaited(showDoseActions(context, ref, doses.single));
      } else {
        unawaited(_showGroup(context, ref));
      }
    }

    return Semantics(
      button: true,
      label: l10n.doseStatusLabel(names, time, status.label),
      excludeSemantics: true,
      onTap: open,
      child: Material(
        key: ValueKey('senior-group-$time'),
        color: palette.surface,
        borderRadius: BorderRadius.circular(22),
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: open,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            child: Row(
              children: [
                StatusSquare(status: status),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(time, style: textTheme.titleLarge),
                      Text(
                        allTaken ? l10n.todayAllTakenShort : names,
                        style: textTheme.bodyLarge
                            ?.copyWith(color: palette.inkMuted),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Several doses at one time: pick one, then its actions.
  Future<void> _showGroup(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final dose in doses)
              ListTile(
                key: ValueKey('senior-group-dose-${dose.occurrence.key}'),
                title: Text(medicationTitle(dose)),
                subtitle: Text(doseStatusText(l10n, dose.status)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(showDoseActions(context, ref, dose));
                },
              ),
          ],
        ),
      ),
    );
  }
}
