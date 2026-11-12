import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/db/database.dart';
import '../../routing/routes.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/formatters.dart';
import '../common/gap.dart';
import '../common/pillpal_card.dart';
import '../common/status_kind.dart';
import '../common/status_pill.dart';
import '../family/profile_context.dart';
import '../schedule/schedule_text.dart';
import '../stock/stock_level.dart';
import '../stock/stock_providers.dart';
import 'medication_form.dart';
import 'medication_providers.dart';

/// A medication in the list (board B-Medications): a soft tile, the name with
/// the strength, the schedule, and a meta row with who sees it and what is
/// left. Running low is a soft pill with an icon and the days, never red.
///
/// From the compact text scale on the tile and the chevron go away and the
/// whole card stays tappable (B2-README section 9.7). The card has the key
/// `medication-<id>`, the low-stock pill `stock-pill-<id>`.
class MedicationCard extends ConsumerWidget {
  /// Creates the card; [access] is the role on the medication's profile.
  const MedicationCard({
    required this.medication,
    required this.access,
    super.key,
  });

  /// The medication.
  final MedicationRow medication;

  /// What the account may do on the profile; null while unknown.
  final ProfileAccess? access;

  /// Fail closed: nothing opens until the role on the profile is known.
  bool get _canEdit {
    final role = access;
    if (role == null) {
      return false;
    }
    return role.canEditMedication(
      privacy: medication.privacy,
      redacted: medication.redacted,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final compact =
        MediaQuery.textScalerOf(context).scale(1) >= PillPalSizes.compactScale;
    final schedules =
        ref.watch(medicationSchedulesProvider(medication.id)).valueOrNull;
    // Never the strength of a redacted medication, whatever the row holds.
    final strength = medication.redacted ? null : medication.strengthText;
    final name =
        medication.redacted ? l10n.redactedMedication : (medication.name ?? '');
    final summary = schedules == null || schedules.isEmpty
        ? l10n.noSchedule
        : schedules
            .map((s) => scheduleSummary(l10n, s.rule, locale))
            .join('\n');
    final editable = _canEdit;
    return PillPalCard(
      key: ValueKey('medication-${medication.id}'),
      padding: EdgeInsets.zero,
      child: MergeSemantics(
        child: InkWell(
          onTap: editable
              ? () => context.push(AppRoutes.medication(medication.id))
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: PillPalSpacing.lg,
              vertical: PillPalSpacing.md,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!compact) ...[
                  const _Tile(),
                  const Gap.h(PillPalSpacing.md),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        strength == null || strength.isEmpty
                            ? name
                            : '$name $strength',
                        style: textTheme.rowTitleStrong,
                      ),
                      Text(
                        summary,
                        style: textTheme.bodyMedium
                            ?.copyWith(color: palette.inkMuted),
                      ),
                      const Gap.v(PillPalSpacing.sm),
                      _MetaRow(medication: medication),
                    ],
                  ),
                ),
                if (editable && !compact) ...[
                  const Gap.h(PillPalSpacing.sm),
                  ExcludeSemantics(
                    child: Icon(
                      Icons.chevron_right,
                      size: PillPalSizes.iconInline,
                      color: palette.inkMuted,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The 40 disc with a pill icon.
class _Tile extends StatelessWidget {
  const _Tile();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: palette.actionSoft,
        shape: const CircleBorder(),
      ),
      child: SizedBox.square(
        dimension: PillPalSizes.avatarSm,
        child: ExcludeSemantics(
          child: Icon(
            Icons.medication_outlined,
            size: PillPalSizes.iconInline,
            color: palette.onActionSoft,
          ),
        ),
      ),
    );
  }
}

/// Who sees the medication, and what is left of it.
class _MetaRow extends ConsumerWidget {
  const _MetaRow({required this.medication});

  final MedicationRow medication;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    // A redacted row shows time and status only: no stock, in any form.
    final StockLevel level = medication.redacted
        ? const StockNotTracked()
        : ref.watch(stockLevelProvider(medication.id));
    final days = level is StockKnown ? level.daysLeft : null;
    final low = days != null && isLowStock(medication, level);
    final (IconData icon, String label) =
        switch (MedicationPrivacy.of(medication.privacy)) {
      MedicationPrivacy.shared => (Icons.people_outline, l10n.privacyShared),
      MedicationPrivacy.anonymous => (
          Icons.visibility_off_outlined,
          l10n.privacyAnonymous,
        ),
      MedicationPrivacy.hidden => (Icons.lock_outline, l10n.privacyHidden),
    };
    return Wrap(
      spacing: PillPalSpacing.md,
      runSpacing: PillPalSpacing.xs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _Meta(icon: icon, text: label),
        if (low)
          StatusPill(
            StatusKind.lowStock,
            key: ValueKey('stock-pill-${medication.id}'),
            label: l10n.stockPillDays(days),
          )
        else if (level is StockKnown)
          _Meta(
            text: l10n.stockLeft(
              formatDose(l10n, level.remaining, level.unit.name, locale),
            ),
          ),
      ],
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.text, this.icon});

  final String text;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: context.palette.inkMuted);
    final glyph = icon;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (glyph != null) ...[
          // The icon grows with the text beside it.
          ExcludeSemantics(
            child: Icon(
              glyph,
              size: MediaQuery.textScalerOf(context)
                  .scale(style?.fontSize ?? kDefaultFontSize),
              color: style?.color,
            ),
          ),
          const Gap.h(PillPalSpacing.xs),
        ],
        Flexible(child: Text(text, style: style)),
      ],
    );
  }
}
