import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
import '../common/local_time.dart';
import '../doses/scheduled_doses.dart';
import '../family/profile_context.dart';
import '../medications/medication_providers.dart';
import 'schedule_draft.dart';
import 'schedule_editor_view.dart';
import 'schedule_providers.dart';

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
    // Keep the form while a provider reloads (a sync touching the rows);
    // only the very first load shows the spinner, or typed input is lost.
    if ((medication.isLoading && !medication.hasValue) ||
        (schedule.isLoading && !schedule.hasValue)) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final row = medication.valueOrNull;
    final existing = schedule.valueOrNull;
    if (row == null || (id != null && existing == null)) {
      return _message(l10n.medicationNotFound);
    }
    // Fail closed: nothing is editable until the role is known.
    final role = ref.watch(medicationAccessProvider(medicationId));
    if (role.isLoading && !role.hasValue) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final access = role.valueOrNull;
    if (access == null ||
        !access.canEditMedication(
          privacy: row.privacy,
          redacted: row.redacted,
        )) {
      // A viewer, an editor on a medication that is not `shared`, or an
      // unknown role.
      return _message(l10n.medicationReadOnly);
    }
    final today = _courseToday(ref, row, access);
    return _editor(row, existing?.rule, access, today);
  }

  Widget _message(String text) =>
      Scaffold(appBar: AppBar(), body: Center(child: Text(text)));

  Widget _editor(
    MedicationRow row,
    ScheduleRule? rule,
    ProfileAccess access,
    LocalDate today,
  ) {
    return ScheduleEditorView(
      key: ValueKey(scheduleId ?? 'new'),
      medication: row,
      scheduleId: scheduleId,
      initial: rule == null
          ? ScheduleDraft.initial(today)
          : ScheduleDraft.fromRule(rule),
      today: today,
      ended: rule != null && hasEndedBy(rule, today),
      started: rule != null &&
          hasHistoryBefore(rule, today) &&
          !hasEndedBy(rule, today),
      // Editors change schedules but never delete them (D3).
      canDelete: access.canDelete,
    );
  }

  /// Course dates are in the medication's zone: for another person's
  /// profile that is the profile's zone (D4), not the device's.
  LocalDate _courseToday(
    WidgetRef ref,
    MedicationRow row,
    ProfileAccess access,
  ) {
    if (access.isOwnSelf) {
      return ref.watch(todayDateProvider);
    }
    return localDateOf(
      ref.watch(nowProvider),
      effectiveZone(
        row,
        access.localZone(ref.watch(deviceTimeZoneProvider)),
      ),
    );
  }
}
