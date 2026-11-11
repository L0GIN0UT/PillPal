import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
import '../../data/repositories/local_writer.dart';
import '../../theme/spacing.dart';
import '../common/banner_tone.dart';
import '../common/error_snack_bar.dart';
import '../common/gap.dart';
import '../common/pillpal_banner.dart';
import '../common/pillpal_card.dart';
import '../common/pillpal_icon_button.dart';
import '../common/removal_dialog.dart';
import '../common/section_header.dart';
import 'course_card.dart';
import 'schedule_draft.dart';
import 'schedule_edit.dart';
import 'schedule_pickers.dart';
import 'schedule_providers.dart';
import 'schedule_save_bar.dart';
import 'schedule_widgets.dart';

/// The schedule form once the medication and the role are known: kind,
/// times with per-time doses and the course dates.
class ScheduleEditorView extends ConsumerStatefulWidget {
  /// Creates the form.
  const ScheduleEditorView({
    required this.medication,
    required this.scheduleId,
    required this.initial,
    required this.today,
    required this.ended,
    required this.started,
    required this.canDelete,
    super.key,
  });

  /// The medication the schedule belongs to.
  final MedicationRow medication;

  /// Schedule being edited; null creates one.
  final String? scheduleId;

  /// The form's starting content.
  final ScheduleDraft initial;

  /// Today (device zone).
  final LocalDate today;

  /// The schedule has ended: shown, not edited (ADR 0003 §2).
  final bool ended;

  /// The schedule has past days: saving splits it (ADR 0003 §1).
  final bool started;

  /// Whether the role may delete schedules.
  final bool canDelete;

  @override
  ConsumerState<ScheduleEditorView> createState() => _EditorState();
}

class _EditorState extends ConsumerState<ScheduleEditorView> {
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
    final id = widget.scheduleId;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.scheduleTitle),
        actions: [
          if (id != null && widget.canDelete)
            PillPalIconButton(
              key: const Key('schedule-delete'),
              tooltip: l10n.deleteSchedule,
              icon: Icons.delete_outline,
              onPressed: () => _delete(id),
            ),
        ],
      ),
      // The save bar below handles the bottom inset.
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: PillPalSpacing.form,
          children: [
            ..._header(l10n),
            SectionHeader(l10n.scheduleHowOften),
            KindSelector(
              value: _draft.kind,
              onChanged: (kind) => _update(_draft.copyWith(kind: kind)),
            ),
            ..._kindSection(l10n),
            SectionHeader(l10n.courseTitle),
            _courseCard(),
          ],
        ),
      ),
      bottomNavigationBar: ScheduleSaveBar(
        errors: _errors,
        onSave: _saving || widget.ended ? null : _save,
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
        style: Theme.of(context).textTheme.bodySmall,
      ),
      if (widget.ended || widget.started) ...[
        const Gap.v(PillPalSpacing.md),
        PillPalBanner(
          key: const Key('schedule-note'),
          tone: BannerTone.info,
          body: widget.ended ? l10n.scheduleEndedNote : l10n.scheduleSplitNote,
        ),
      ],
    ];
  }

  List<Widget> _kindSection(AppLocalizations l10n) {
    if (_draft.kind == RuleKind.asNeeded) {
      return [
        const Gap.v(PillPalSpacing.lg),
        PillPalCard(
          child: Text(
            l10n.asNeededHint,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
      ];
    }
    return [
      if (_draft.kind == RuleKind.weekdays) ...[
        const Gap.v(PillPalSpacing.lg),
        WeekdaySelector(
          selected: _draft.weekdays,
          onToggle: (day) => _update(_draft.toggleWeekday(day)),
        ),
      ],
      if (_draft.kind == RuleKind.intervalDays) ...[
        const Gap.v(PillPalSpacing.lg),
        IntervalStepper(
          value: _draft.intervalDays,
          onChanged: (days) => _update(_draft.withInterval(days)),
        ),
      ],
      SectionHeader(l10n.timesAndDoses),
      PillPalCard.rows(
        rows: [
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
            // Inset like the time rows, so the plus lines up with the times.
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: PillPalSpacing.lg,
                  vertical: PillPalSpacing.xs,
                ),
                child: TextButton.icon(
                  key: const Key('slot-add'),
                  onPressed: () => _update(_draft.addSlot()),
                  icon: const Icon(Icons.add),
                  label: Text(l10n.addTime),
                ),
              ),
            ),
        ],
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
    // Close the keyboard: the save bar would otherwise stay behind it.
    FocusManager.instance.primaryFocus?.unfocus();
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
