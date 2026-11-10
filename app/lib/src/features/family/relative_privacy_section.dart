import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
import '../../data/providers.dart';
import '../../data/repositories/local_writer.dart';
import '../../theme/app_theme.dart';
import '../../theme/spacing.dart';
import '../common/error_snack_bar.dart';
import '../common/gap.dart';
import '../common/pillpal_card.dart';
import '../common/pillpal_segmented.dart';
import '../common/section_header.dart';
import '../medications/medication_form.dart';
import '../medications/medication_providers.dart';
import 'profile_context.dart';

/// The live medications of [profileId], for the privacy editor of a link.
final relativePrivacyMedicationsProvider = StreamProvider.autoDispose
    .family<List<MedicationRow>, String>((ref, profileId) {
  return ref.watch(medicationsRepositoryProvider).watchForProfile(profileId);
});

/// "Что видит <имя>" on the screen of an outgoing link (decision D4): the
/// privacy level of each medication of the profile as a segmented control.
///
/// Privacy is a property of the medication, not of the link, so a change
/// applies to every relative at once and the screen says so. It is written
/// through the same service call as the medication form (one outbox entry,
/// the same fields; no sync change). Only the owner of a live profile gets
/// the editor: for anyone else the section is empty, whatever the caller
/// passes.
class RelativePrivacySection extends ConsumerStatefulWidget {
  /// Creates the section for the medications of [profileId]; [name] is the
  /// relative the heading speaks of.
  const RelativePrivacySection({
    required this.profileId,
    required this.name,
    super.key,
  });

  /// The profile whose medications are listed.
  final String profileId;

  /// The relative's name, for the heading.
  final String name;

  @override
  ConsumerState<RelativePrivacySection> createState() => _SectionState();
}

class _SectionState extends ConsumerState<RelativePrivacySection> {
  /// Levels being written, by medication id: shown at once, and the row is
  /// off until the write ends (no double write).
  final Map<String, MedicationPrivacy> _pending = {};

  @override
  Widget build(BuildContext context) {
    final profileId = widget.profileId;
    final access = ref.watch(profileAccessProvider(profileId)).valueOrNull;
    final medications =
        ref.watch(relativePrivacyMedicationsProvider(profileId)).valueOrNull;
    if (access == null ||
        !access.isOwner ||
        !access.canChangePrivacy ||
        medications == null ||
        medications.isEmpty) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(l10n.relativeSeesTitle(widget.name)),
        Text(
          l10n.privacyAppliesToAll,
          key: const Key('relative-privacy-all-note'),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const Gap.v(PillPalSpacing.sm),
        PillPalCard.rows(
          rows: [
            for (final medication in medications)
              _MedicationPrivacyRow(
                key: ValueKey('relative-privacy-${medication.id}'),
                medication: medication,
                shown: _pending[medication.id] ??
                    MedicationPrivacy.of(medication.privacy),
                busy: _pending.containsKey(medication.id),
                onChanged: (level) => _change(medication, level),
              ),
          ],
        ),
      ],
    );
  }

  Future<void> _change(
    MedicationRow medication,
    MedicationPrivacy level,
  ) async {
    if (level.wire == medication.privacy ||
        _pending.containsKey(medication.id)) {
      return;
    }
    setState(() => _pending[medication.id] = level);
    try {
      await ref
          .read(medicationServiceProvider)
          .setPrivacy(medication.id, level);
    } on DataException {
      if (mounted) {
        showErrorSnackBar(context);
      }
    } finally {
      if (mounted) {
        setState(() => _pending.remove(medication.id));
      }
    }
  }
}

class _MedicationPrivacyRow extends StatelessWidget {
  const _MedicationPrivacyRow({
    required this.medication,
    required this.shown,
    required this.busy,
    required this.onChanged,
    super.key,
  });

  final MedicationRow medication;
  final MedicationPrivacy shown;
  final bool busy;
  final ValueChanged<MedicationPrivacy> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final stored = medication.name;
    final name = stored == null || stored.trim().isEmpty
        ? l10n.redactedMedication
        : stored;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: PillPalSpacing.lg,
        vertical: PillPalSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(name, style: Theme.of(context).textTheme.rowTitleStrong),
          const Gap.v(PillPalSpacing.sm),
          Semantics(
            container: true,
            label: '${l10n.privacyTitle}: $name',
            child: IgnorePointer(
              ignoring: busy,
              child: PillPalSegmented<MedicationPrivacy>(
                options: {
                  MedicationPrivacy.shared: l10n.privacyShared,
                  MedicationPrivacy.anonymous: l10n.privacyAnonymous,
                  MedicationPrivacy.hidden: l10n.privacyHidden,
                },
                selected: shown,
                onChanged: onChanged,
                keyOf: (level) =>
                    ValueKey('relative-privacy-${medication.id}-${level.wire}'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
