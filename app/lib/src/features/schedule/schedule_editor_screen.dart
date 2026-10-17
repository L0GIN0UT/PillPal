import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
import '../../data/repositories/local_writer.dart';
import '../common/error_snack_bar.dart';
import '../common/info_note.dart';
import '../common/local_time.dart';
import '../common/removal_dialog.dart';
import '../doses/scheduled_doses.dart';
import '../medications/medication_providers.dart';
import 'course_card.dart';
import 'schedule_draft.dart';
import 'schedule_edit.dart';
import 'schedule_pickers.dart';
import 'schedule_providers.dart';
import 'schedule_text.dart';
import 'schedule_widgets.dart';

/// Create ([scheduleId] null) or edit a schedule of a medication (mockup
/// "Schedule"): every rule kind, times with per-time doses, course dates.
class ScheduleEditorScreen extends ConsumerWidget {
  /// Creates the screen.
  const ScheduleEditorScreen({
    required this.medicationId,
    this.scheduleId,
    super.key,
  });

  /// Owning medication.
  final String medicationId;

  /// Schedule to edit; null creates one.
  final String? scheduleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final medication = ref.watch(medicationByIdProvider(medicationId));
    final id = scheduleId;
    final AsyncValue<ParsedSchedule?> schedule = id == null
        ? const AsyncData(null)
        : ref.watch(
            scheduleByIdProvider((medicationId: medicationId, scheduleId: id)),
          );
    if (medication.isLoading || schedule.isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final row = medication.valueOrNull;
    final existing = schedule.valueOrNull;
    if (row == null || (id != null && existing == null)) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(l10n.medicationNotFound)),
      );
    }
    final today = ref.watch(todayDateProvider);
    final rule = existing?.rule;
    return _ScheduleEditorView(
      key: ValueKey(id ?? 'new'),
      medication: row,
      scheduleId: id,
      initial: rule == null
          ? ScheduleDraft.initial(today)
          : ScheduleDraft.fromRule(rule),
      today: today,
      ended: rule != null && hasEndedBy(rule, today),
      started: rule != null &&
          hasHistoryBefore(rule, today) &&
          !hasEndedBy(rule, today),
    );
  }
}

class _ScheduleEditorView extends ConsumerStatefulWidget {
  const _ScheduleEditorView({
    required this.medication,
    required this.scheduleId,
    required this.initial,
    required this.today,
    required this.ended,
    required this.started,
    super.key,
  });

  final MedicationRow medication;
  final String? scheduleId;
  final ScheduleDraft initial;

  /// Today (device zone).
  final LocalDate today;

  /// The schedule has ended: shown, not edited (ADR 0003 §2).
  final bool ended;

  /// The schedule has past days: saving splits it (ADR 0003 §1).
  final bool started;

  @override
  ConsumerState<_ScheduleEditorView> createState() => _ScheduleEditorState();
}

class _ScheduleEditorState extends ConsumerState<_ScheduleEditorView> {
  late ScheduleDraft _draft = widget.initial;
  List<ScheduleDraftError> _errors = const [];
  bool _saving = false;

  void _update(ScheduleDraft draft) => setState(() {
        _draft = draft;
        _errors = const [];
      });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final id = widget.scheduleId;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.scheduleTitle),
        actions: [
          if (id != null)
            IconButton(
              key: const Key('schedule-delete'),
              tooltip: l10n.deleteSchedule,
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _delete(id),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
          children: [
            ..._header(l10n),
            const SizedBox(height: 16),
            KindSelector(
              value: _draft.kind,
              onChanged: (kind) => _update(_draft.copyWith(kind: kind)),
            ),
            const SizedBox(height: 16),
            ..._kindSection(l10n),
            const SizedBox(height: 16),
            _courseCard(),
            for (final error in _errors)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  scheduleErrorText(l10n, error),
                  style: textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('schedule-save'),
              onPressed: _saving || widget.ended ? null : _save,
              child: Text(l10n.save),
            ),
          ],
        ),
      ),
    );
  }

  /// The medication, and why saving splits or is not possible (ADR 0003).
  List<Widget> _header(AppLocalizations l10n) {
    final medication = widget.medication;
    final strength = medication.strengthText;
    return [
      Text(
        strength == null || strength.isEmpty
            ? medication.name ?? ''
            : '${medication.name ?? ''} $strength',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      if (widget.ended || widget.started) ...[
        const SizedBox(height: 12),
        InfoNote(
          key: const Key('schedule-note'),
          text: widget.ended ? l10n.scheduleEndedNote : l10n.scheduleSplitNote,
        ),
      ],
    ];
  }

  List<Widget> _kindSection(AppLocalizations l10n) {
    final textTheme = Theme.of(context).textTheme;
    if (_draft.kind == RuleKind.asNeeded) {
      return [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(l10n.asNeededHint, style: textTheme.bodyMedium),
          ),
        ),
      ];
    }
    return [
      if (_draft.kind == RuleKind.weekdays) ...[
        WeekdaySelector(
          selected: _draft.weekdays,
          onToggle: (day) => _update(_draft.toggleWeekday(day)),
        ),
        const SizedBox(height: 16),
      ],
      if (_draft.kind == RuleKind.intervalDays) ...[
        IntervalStepper(
          value: _draft.intervalDays,
          onChanged: (days) => _update(_draft.withInterval(days)),
        ),
        const SizedBox(height: 16),
      ],
      Text(l10n.timesAndDoses, style: textTheme.titleMedium),
      const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < _draft.slots.length; i++)
                SlotRow(
                  slot: _draft.slots[i],
                  onPickTime: () => _pickTime(i),
                  onChanged: (slot) => _update(_draft.updateSlot(i, slot)),
                  onRemove: _draft.slots.length > 1
                      ? () => _update(_draft.removeSlot(i))
                      : null,
                ),
              if (_draft.slots.length < RuleLimits.maxSlots)
                TextButton.icon(
                  key: const Key('slot-add'),
                  onPressed: () => _update(_draft.addSlot()),
                  icon: const Icon(Icons.add),
                  label: Text(l10n.addTime),
                ),
            ],
          ),
        ),
      ),
    ];
  }

  Widget _courseCard() {
    final medication = widget.medication;
    // A new (or not yet started) course starting before today makes its past
    // days count as missed; a started one is split and keeps its past.
    final startsInPast = !widget.started &&
        !widget.ended &&
        _draft.startDate.isBefore(widget.today);
    return CourseCard(
      start: _draft.startDate,
      end: _draft.endDate,
      zone: medication.tzMode == 'fixed' ? (medication.fixedTz ?? '') : null,
      startsInPast: startsInPast,
      onPickStart: () => _pickDate(start: true),
      onPickEnd: () => _pickDate(start: false),
      onClearEnd: () => _update(_draft.copyWith(clearEnd: true)),
    );
  }

  Future<void> _pickTime(int index) async {
    final slot = _draft.slots[index];
    final time = await pickSlotTime(context, slot.time);
    if (time == null || !mounted) {
      return;
    }
    if (time != slot.time && _draft.slots.any((s) => s.time == time)) {
      setState(() => _errors = const [ScheduleDraftError.timesDuplicate]);
      return;
    }
    _update(_draft.updateSlot(index, slot.copyWith(time: time)));
  }

  Future<void> _pickDate({required bool start}) async {
    final current =
        start ? _draft.startDate : (_draft.endDate ?? _draft.startDate);
    final date = await pickLocalDate(context, current);
    if (date == null || !mounted) {
      return;
    }
    _update(start
        ? _draft.copyWith(startDate: date)
        : _draft.copyWith(endDate: date));
  }

  Future<void> _save() async {
    final errors = _draft.validate();
    if (errors.isNotEmpty) {
      setState(() => _errors = errors);
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(scheduleServiceProvider).save(
            medicationId: widget.medication.id,
            scheduleId: widget.scheduleId,
            rule: _draft.toRuleJson(),
          );
      if (mounted) {
        context.pop();
      }
    } on DataException {
      _fail(ScheduleDraftError.ruleInvalid);
    } on ScheduleEditException catch (error) {
      _fail(
        error.error == ScheduleEditError.ended
            ? ScheduleDraftError.ended
            : ScheduleDraftError.endBeforeToday,
      );
    } on Object {
      // Anything else (storage): reported, and the draft stays for a retry.
      if (mounted) {
        setState(() => _saving = false);
        showErrorSnackBar(context);
      }
    }
  }

  void _fail(ScheduleDraftError error) {
    if (mounted) {
      setState(() {
        _saving = false;
        _errors = [error];
      });
    }
  }

  Future<void> _delete(String id) async {
    final l10n = AppLocalizations.of(context);
    final choice = await askRemoval(
      context,
      title: l10n.deleteScheduleTitle,
      plainBody: l10n.deleteScheduleBody,
      historyBody: l10n.removeScheduleBody,
      hasHistory: widget.started || widget.ended,
      canFinish: widget.started,
    );
    if (choice == null || !mounted) {
      return;
    }
    // The editor is replaced once the schedule disappears from the stream,
    // so the router is captured before the write.
    final router = GoRouter.of(context);
    final service = ref.read(scheduleServiceProvider);
    try {
      switch (choice) {
        case RemovalChoice.finish:
          await service.finish(
            medicationId: widget.medication.id,
            scheduleId: id,
          );
        case RemovalChoice.delete:
          await service.delete(id);
      }
      router.pop();
    } on Object {
      if (mounted) {
        showErrorSnackBar(context);
      }
    }
  }
}
