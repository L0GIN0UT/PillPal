import 'package:flutter/foundation.dart';
import 'package:pillpal_core/pillpal_core.dart';

/// Limits of rule v1 (docs/spec/schedule.md §1.1, §1.3).
abstract final class RuleLimits {
  /// Smallest `interval_days`.
  static const int minInterval = 2;

  /// Largest `interval_days`.
  static const int maxInterval = 366;

  /// Most time slots per rule.
  static const int maxSlots = 24;

  /// Hours between a new slot and the previous one.
  static const int newSlotStepHours = 4;
}

/// Editor validation codes (localized by the screen).
enum ScheduleDraftError {
  /// `weekdays` kind without days.
  weekdaysEmpty,

  /// No time for a scheduled kind.
  timesEmpty,

  /// Two slots with the same time.
  timesDuplicate,

  /// A dose amount is not a positive decimal (≤ 3 fraction digits).
  amountInvalid,

  /// Course end before its start.
  endBeforeStart,

  /// Interval outside 2..366.
  intervalRange,

  /// A started schedule would end before today (ADR 0003: that is
  /// "finish", not an edit).
  endBeforeToday,

  /// The schedule has ended and is no longer edited (ADR 0003 §2).
  ended,

  /// Rejected by `ScheduleRule.fromJson` for another reason.
  ruleInvalid,
}

/// One time slot as edited: `HH:MM`, amount as typed, unit.
@immutable
class SlotDraft {
  /// Creates a slot.
  const SlotDraft(
      {required this.time, required this.amount, required this.unit});

  /// `HH:MM`.
  final String time;

  /// Amount as typed ("1", "0,5").
  final String amount;

  /// Dose unit.
  final DoseUnit unit;

  /// The amount with a decimal point (the rule's notation).
  String get normalizedAmount => amount.trim().replaceAll(',', '.');

  /// Copy with fields replaced.
  SlotDraft copyWith({String? time, String? amount, DoseUnit? unit}) =>
      SlotDraft(
        time: time ?? this.time,
        amount: amount ?? this.amount,
        unit: unit ?? this.unit,
      );
}

/// The schedule editor's state; [toRuleJson] produces a rule v1 document.
@immutable
class ScheduleDraft {
  /// Creates a draft.
  const ScheduleDraft({
    required this.kind,
    required this.weekdays,
    required this.intervalDays,
    required this.slots,
    required this.startDate,
    required this.endDate,
  });

  /// A new daily schedule at 08:00, one tablet, starting [today].
  factory ScheduleDraft.initial(LocalDate today) => ScheduleDraft(
        kind: RuleKind.daily,
        weekdays: {today.weekday},
        intervalDays: RuleLimits.minInterval,
        slots: const [
          SlotDraft(time: '08:00', amount: '1', unit: DoseUnit.tablet),
        ],
        startDate: today,
        endDate: null,
      );

  /// The draft of a stored [rule].
  factory ScheduleDraft.fromRule(ScheduleRule rule) {
    final initial = ScheduleDraft.initial(rule.startDate);
    return ScheduleDraft(
      kind: rule.kind,
      weekdays: rule.weekdays?.toSet() ?? initial.weekdays,
      intervalDays: rule.intervalDays ?? initial.intervalDays,
      slots: rule.times.isEmpty
          ? initial.slots
          : [
              for (final slot in rule.times)
                SlotDraft(
                  time: slot.time,
                  amount: slot.dose.amount,
                  unit: slot.dose.unit,
                ),
            ],
      startDate: rule.startDate,
      endDate: rule.endDate,
    );
  }

  /// Rule kind.
  final RuleKind kind;

  /// ISO weekdays (Monday = 1) for [RuleKind.weekdays].
  final Set<int> weekdays;

  /// N for [RuleKind.intervalDays].
  final int intervalDays;

  /// Times with doses (kept for as-needed too, but not saved).
  final List<SlotDraft> slots;

  /// Course start (inclusive).
  final LocalDate startDate;

  /// Course end (inclusive), null when open-ended.
  final LocalDate? endDate;

  /// Copy with fields replaced; [clearEnd] removes the end date.
  ScheduleDraft copyWith({
    RuleKind? kind,
    Set<int>? weekdays,
    int? intervalDays,
    List<SlotDraft>? slots,
    LocalDate? startDate,
    LocalDate? endDate,
    bool clearEnd = false,
  }) {
    return ScheduleDraft(
      kind: kind ?? this.kind,
      weekdays: weekdays ?? this.weekdays,
      intervalDays: intervalDays ?? this.intervalDays,
      slots: slots ?? this.slots,
      startDate: startDate ?? this.startDate,
      endDate: clearEnd ? null : (endDate ?? this.endDate),
    );
  }

  /// Adds or removes ISO [weekday].
  ScheduleDraft toggleWeekday(int weekday) {
    final days = {...weekdays};
    if (!days.remove(weekday)) {
      days.add(weekday);
    }
    return copyWith(weekdays: days);
  }

  /// Interval clamped to 2..366.
  ScheduleDraft withInterval(int days) => copyWith(
        intervalDays:
            days.clamp(RuleLimits.minInterval, RuleLimits.maxInterval),
      );

  /// Adds a slot a few hours after the last one, with the same dose.
  ScheduleDraft addSlot() {
    if (slots.length >= RuleLimits.maxSlots) {
      return this;
    }
    final last = slots.isEmpty
        ? const SlotDraft(time: '08:00', amount: '1', unit: DoseUnit.tablet)
        : slots.last;
    final taken = {for (final slot in slots) slot.time};
    var hour = int.parse(last.time.substring(0, 2));
    final minute = last.time.substring(3);
    for (var step = 0; step < Duration.hoursPerDay; step++) {
      hour = (hour + (step == 0 ? RuleLimits.newSlotStepHours : 1)) %
          Duration.hoursPerDay;
      final time = '${hour.toString().padLeft(2, '0')}:$minute';
      if (!taken.contains(time)) {
        return copyWith(slots: [...slots, last.copyWith(time: time)]);
      }
    }
    return this;
  }

  /// Replaces slot [index].
  ScheduleDraft updateSlot(int index, SlotDraft slot) =>
      copyWith(slots: [...slots]..[index] = slot);

  /// Removes slot [index].
  ScheduleDraft removeSlot(int index) =>
      copyWith(slots: [...slots]..removeAt(index));

  /// The rule v1 JSON (docs/spec/schedule.md §1).
  Map<String, Object?> toRuleJson() {
    final sorted = [...slots]..sort((a, b) => a.time.compareTo(b.time));
    return {
      'v': 1,
      'kind': kind.wireName,
      'start_date': startDate.toString(),
      'end_date': endDate?.toString(),
      if (kind == RuleKind.weekdays) 'weekdays': (weekdays.toList()..sort()),
      if (kind == RuleKind.intervalDays) 'interval_days': intervalDays,
      'times': kind == RuleKind.asNeeded
          ? const <Object?>[]
          : [
              for (final slot in sorted)
                {
                  'time': slot.time,
                  'dose': {
                    'amount': slot.normalizedAmount,
                    'unit': slot.unit.name,
                  },
                },
            ],
    };
  }

  /// Problems preventing a save; empty when [toRuleJson] is a valid rule.
  List<ScheduleDraftError> validate() {
    final errors = <ScheduleDraftError>[];
    final end = endDate;
    if (end != null && end.isBefore(startDate)) {
      errors.add(ScheduleDraftError.endBeforeStart);
    }
    if (kind == RuleKind.weekdays && weekdays.isEmpty) {
      errors.add(ScheduleDraftError.weekdaysEmpty);
    }
    if (kind == RuleKind.intervalDays &&
        (intervalDays < RuleLimits.minInterval ||
            intervalDays > RuleLimits.maxInterval)) {
      errors.add(ScheduleDraftError.intervalRange);
    }
    if (kind != RuleKind.asNeeded) {
      if (slots.isEmpty) {
        errors.add(ScheduleDraftError.timesEmpty);
      }
      if ({for (final slot in slots) slot.time}.length != slots.length) {
        errors.add(ScheduleDraftError.timesDuplicate);
      }
      if (slots.any((slot) => !_isValidAmount(slot.normalizedAmount))) {
        errors.add(ScheduleDraftError.amountInvalid);
      }
    }
    if (errors.isEmpty) {
      try {
        ScheduleRule.fromJson(toRuleJson());
      } on RuleValidationError {
        errors.add(ScheduleDraftError.ruleInvalid);
      }
    }
    return errors;
  }
}

bool _isValidAmount(String amount) {
  try {
    normalizeAmount(amount);
    return true;
  } on RuleValidationError {
    return false;
  }
}
