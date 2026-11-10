import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/repositories/dose_events_repository.dart';
import '../../theme/spacing.dart';
import '../common/error_snack_bar.dart';
import '../common/gap.dart';
import '../doses/dose_providers.dart';
import '../doses/dose_status.dart';
import '../doses/scheduled_doses.dart';
import 'dose_tile.dart';
import 'senior_groups.dart';
import 'senior_now_card.dart';
import 'today_state.dart';

/// Senior-mode Today (board B-TodaySenior, light and dark): the «Сейчас»
/// card at senior sizes for the dose to take now, then the day grouped by
/// time.
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
  Timer? _undoGuard;
  bool _undoArmed = false;

  @override
  void dispose() {
    _timer?.cancel();
    _undoGuard?.cancel();
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
      _undoGuard?.cancel();
      _undoArmed = false;
      _undoGuard = Timer(DoseTiming.undoGuard, () => _undoArmed = true);
      setState(() => _confirmation = (dose: dose, type: type, eventId: id));
    } on Object {
      if (mounted) {
        showErrorSnackBar(context);
      }
    }
  }

  Future<void> _undo(SeniorConfirmation confirmation) async {
    // The button replaced "take" under the finger: an immediate second tap
    // is the same gesture, not an undo (PR #7 review).
    if (!_undoArmed) {
      return;
    }
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
    final groups = <String, List<ScheduledDose>>{};
    for (final dose in state.doses) {
      final key = dose.occurrence.key;
      if (key == current?.occurrence.key ||
          key == confirmation?.dose.occurrence.key) {
        continue;
      }
      (groups[doseTime(dose)] ??= <ScheduledDose>[]).add(dose);
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
          const Gap.v(PillPalSpacing.listGap),
          SeniorTimeGroup(time: entry.key, doses: entry.value),
        ],
      ],
    );
  }
}
