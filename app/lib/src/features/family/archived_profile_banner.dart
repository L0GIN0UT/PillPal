import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/spacing.dart';
import '../common/confirm_dialog.dart';
import '../common/error_snack_bar.dart';
import '../common/formatters.dart';
import '../common/local_time.dart';
import '../common/pillpal_banner.dart';
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
    return Padding(
      padding: const EdgeInsets.only(bottom: PillPalSpacing.lg),
      child: PillPalBanner(
        key: const Key('archive-banner'),
        icon: Icons.inventory_2_outlined,
        title: l10n.archiveBannerTitle,
        body: _body(context, ref),
        bodyKey: const Key('archive-banner-body'),
        actions: _actions(context, ref),
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

  List<Widget> _actions(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return [
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
    ];
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
