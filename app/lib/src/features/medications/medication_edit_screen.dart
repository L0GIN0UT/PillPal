import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../common/local_time.dart';
import '../family/profile_context.dart';
import 'medication_form.dart';
import 'medication_form_view.dart';
import 'medication_providers.dart';

/// Add (no [medicationId]) or edit a medication (mockup "AddMedication").
/// Free input is always the way; the catalog (Phase 4) is optional help.
///
/// What the form offers follows the role on the medication's profile:
/// editors change `shared` medications only, never their privacy and never
/// delete (D3); viewers get no form at all.
class MedicationEditScreen extends ConsumerWidget {
  /// Creates the screen.
  const MedicationEditScreen({
    this.medicationId,
    this.profileId,
    this.autoScan = false,
    super.key,
  });

  /// Medication to edit; null adds a new one.
  final String? medicationId;

  /// The profile a new medication goes to; null is the user's own.
  final String? profileId;

  /// Whether a new medication opens the barcode scanner at once.
  final bool autoScan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final tz = ref.watch(deviceTimeZoneProvider);
    final id = medicationId;
    if (id == null) {
      return _newMedication(context, ref, tz);
    }
    final medication = ref.watch(medicationByIdProvider(id));
    return medication.when(
      skipLoadingOnReload: true,
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stack) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(l10n.errorGeneric)),
      ),
      data: (row) {
        if (row == null) {
          return _message(l10n.medicationNotFound);
        }
        // Fail closed: nothing is editable until the role is known.
        final role = ref.watch(medicationAccessProvider(id));
        if (role.isLoading && !role.hasValue) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final access = role.valueOrNull;
        if (access == null ||
            !access.canEditMedication(
              privacy: row.privacy,
              redacted: row.redacted,
            )) {
          return _message(l10n.medicationReadOnly);
        }
        return MedicationFormView(
          key: ValueKey(id),
          medicationId: id,
          row: row,
          profileId: row.profileId,
          access: access,
          initial: MedicationFormInput.fromRow(row, tz),
        );
      },
    );
  }

  Widget _newMedication(BuildContext context, WidgetRef ref, String tz) {
    final l10n = AppLocalizations.of(context);
    final target = profileId;
    final role = ref.watch(profileAccessProvider(target));
    if (role.isLoading && !role.hasValue) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final access = role.valueOrNull;
    // Another profile whose role is unknown (its scope is gone) is read-only;
    // the own profile has none before the first pull, and saving there
    // reports "profile not ready" instead.
    final unknown = access == null && target != null;
    if (unknown || (access != null && !access.canEditMedications)) {
      return _message(l10n.medicationReadOnly);
    }
    return MedicationFormView(
      medicationId: null,
      profileId: target,
      access: access,
      autoScan: autoScan,
      // A new medication of someone else's profile starts `shared`: only the
      // owner and guardians may hide it (D3).
      initial: MedicationFormInput(zone: tz),
    );
  }

  Widget _message(String text) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(text)),
      );
}
