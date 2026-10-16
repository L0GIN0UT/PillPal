import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
import '../../data/repositories/local_writer.dart';
import '../common/formatters.dart';
import '../common/local_time.dart';
import '../doses/scheduled_doses.dart';
import '../medications/medication_providers.dart';
import 'schedule_draft.dart';
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
    final now = ref.watch(nowProvider);
    final today = localDateOf(now, ref.watch(deviceTimeZoneProvider));
    final initial = existing == null
        ? ScheduleDraft.initial(today)
        : ScheduleDraft.fromRule(existing.rule);
    return _ScheduleEditorView(
      key: ValueKey(id ?? 'new'),
      medication: row,
      scheduleId: id,
      initial: initial,
    );
  }
}

class _ScheduleEditorView extends ConsumerStatefulWidget {
  const _ScheduleEditorView({
    required this.medication,
    required this.scheduleId,
    required this.initial,
    super.key,
  });

  final MedicationRow medication;
  final String? scheduleId;
  final ScheduleDraft initial;

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
    final medication = widget.medication;
    final strength = medication.strengthText;
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
            Text(
              strength == null || strength.isEmpty
                  ? medication.name
                  : '${medication.name} $strength',
              style: textTheme.headlineMedium,
            ),
            const SizedBox(height: 16),
            KindSelector(
              value: _draft.kind,
              onChanged: (kind) => _update(_draft.copyWith(kind: kind)),
            ),
            const SizedBox(height: 16),
            ..._kindSection(l10n),
            const SizedBox(height: 16),
            _courseCard(l10n),
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
              onPressed: _saving ? null : _save,
              child: Text(l10n.save),
            ),
          ],
        ),
      ),
    );
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

  Widget _courseCard(AppLocalizations l10n) {
    final locale = Localizations.localeOf(context).toLanguageTag();
    final end = _draft.endDate;
    final medication = widget.medication;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Column(
          children: [
            InfoRow(
              key: const Key('course-start'),
              label: l10n.courseStart,
              value: formatShortDate(_draft.startDate, locale),
              onTap: () => _pickDate(start: true),
            ),
            const Divider(height: 1),
            InfoRow(
              key: const Key('course-end'),
              label: l10n.courseEnd,
              value:
                  end == null ? l10n.courseNoEnd : formatShortDate(end, locale),
              onTap: () => _pickDate(start: false),
              trailing: end == null
                  ? null
                  : IconButton(
                      key: const Key('course-end-clear'),
                      tooltip: l10n.courseClearEnd,
                      icon: const Icon(Icons.close),
                      onPressed: () => _update(_draft.copyWith(clearEnd: true)),
                    ),
            ),
            const Divider(height: 1),
            InfoRow(
              label: l10n.timeZone,
              value: medication.tzMode == 'fixed'
                  ? (medication.fixedTz ?? '')
                  : l10n.localTime,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickTime(int index) async {
    final slot = _draft.slots[index];
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: int.parse(slot.time.substring(0, 2)),
        minute: int.parse(slot.time.substring(3)),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
        child: child ?? const SizedBox.shrink(),
      ),
    );
    if (picked == null || !mounted) {
      return;
    }
    final time = '${picked.hour.toString().padLeft(2, '0')}:'
        '${picked.minute.toString().padLeft(2, '0')}';
    if (time != slot.time && _draft.slots.any((s) => s.time == time)) {
      setState(() => _errors = const [ScheduleDraftError.timesDuplicate]);
      return;
    }
    _update(_draft.updateSlot(index, slot.copyWith(time: time)));
  }

  Future<void> _pickDate({required bool start}) async {
    final current =
        start ? _draft.startDate : (_draft.endDate ?? _draft.startDate);
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(current.year, current.month, current.day),
      firstDate: DateTime(2000),
      lastDate: DateTime(2199, 12, 31),
    );
    if (picked == null || !mounted) {
      return;
    }
    final date = LocalDate(picked.year, picked.month, picked.day);
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
      if (mounted) {
        setState(() {
          _saving = false;
          _errors = const [ScheduleDraftError.ruleInvalid];
        });
      }
    }
  }

  Future<void> _delete(String id) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.deleteScheduleTitle),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            key: const Key('confirm-delete'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    // The editor is replaced once the schedule disappears from the stream,
    // so the router is captured before the write.
    final router = GoRouter.of(context);
    await ref.read(scheduleServiceProvider).delete(id);
    router.pop();
  }
}
