import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/palette.dart';
import '../common/confirm_dialog.dart';
import '../common/error_snack_bar.dart';
import '../common/formatters.dart';
import '../common/local_time.dart';
import 'family_providers.dart';
import 'profile_context.dart';

/// The banner of a read-only archive of a managed profile (D1, ADR 0005
/// §5): nothing can be changed, no reminders fire. While the former owner
/// can still restore, guardians may only leave; after the owner was erased
/// the banner shows the purge date and a guardian or the new owner may
/// delete the archive.
class ArchivedProfileBanner extends ConsumerWidget {
  /// Creates the banner for [access] (which must be archived).
  const ArchivedProfileBanner({required this.access, super.key});

  /// The archived profile.
  final ProfileAccess access;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        key: const Key('archive-banner'),
        color: palette.actionSoft,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.inventory_2_outlined, color: palette.onActionSoft),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      l10n.archiveBannerTitle,
                      style: textTheme.titleMedium?.copyWith(
                        color: palette.onActionSoft,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _body(context, ref),
                key: const Key('archive-banner-body'),
                style: textTheme.bodyLarge?.copyWith(
                  color: palette.onActionSoft,
                ),
              ),
              _actions(context, ref),
            ],
          ),
        ),
      ),
    );
  }

  /// Pending: the owner may still restore. Erased: the purge date.
  String _body(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final purgeAfter = access.archivePurgeAfter;
    if (purgeAfter == null) {
      return l10n.archiveBannerPendingBody;
    }
    final date = localDateOf(purgeAfter, ref.watch(deviceTimeZoneProvider));
    final locale = Localizations.localeOf(context).toLanguageTag();
    return l10n.archiveBannerErasedBody(formatShortDate(date, locale));
  }

  Widget _actions(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    if (!access.canLeave && !access.canPurgeArchive) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: 8,
      children: [
        if (access.canLeave)
          TextButton(
            key: const Key('archive-leave'),
            onPressed: () => _leave(context, ref),
            child: Text(l10n.leaveAction),
          ),
        // Only after the former owner is erased: until then a restore must
        // still find the profile as it was.
        if (access.canPurgeArchive)
          TextButton(
            key: const Key('archive-purge'),
            onPressed: () => _purge(context, ref),
            child: Text(l10n.archivePurgeAction),
          ),
      ],
    );
  }

  Future<void> _leave(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await confirmAction(
      context,
      title: l10n.leaveProfileTitle(access.profile.displayName),
      body: l10n.leaveProfileBody,
      confirmLabel: l10n.leaveAction,
    );
    if (!confirmed || !context.mounted) {
      return;
    }
    runShowingErrors(
      context,
      ref.read(familyActionsProvider).leaveProfile(access.id),
    );
  }

  Future<void> _purge(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await confirmAction(
      context,
      title: l10n.archivePurgeTitle,
      body: l10n.archivePurgeBody,
      confirmLabel: l10n.archivePurgeAction,
    );
    if (!confirmed || !context.mounted) {
      return;
    }
    runShowingErrors(
      context,
      ref.read(familyActionsProvider).purgeArchive(access.id),
    );
  }
}
