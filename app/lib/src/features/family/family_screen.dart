import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../routing/routes.dart';
import '../doses/dose_providers.dart';
import 'family_overview.dart';
import 'family_providers.dart';
import 'family_tiles.dart';
import 'new_relative_banner.dart';
import 'push_unavailable_hint.dart';

/// The Family tab (TZ §2.5): who sees me, whose medications I see, and the
/// profiles I run. Works from the stored links, so it opens offline; links
/// are refreshed on open and after each sync.
class FamilyScreen extends ConsumerStatefulWidget {
  /// Creates the screen.
  const FamilyScreen({super.key});

  @override
  ConsumerState<FamilyScreen> createState() => _FamilyScreenState();
}

class _FamilyScreenState extends ConsumerState<FamilyScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(ref.read(familyActionsProvider).refresh());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final overview = ref.watch(familyOverviewProvider);
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => ref.read(familyActionsProvider).refresh(),
          child: ListView(
            key: const Key('family-list'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
            children: [
              Text(
                l10n.familyTitle,
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 16),
              const NewRelativeBanner(),
              const PushUnavailableHint(),
              ...overview.when(
                skipLoadingOnReload: true,
                data: (data) => _sections(context, data),
                loading: () => const [
                  Center(child: CircularProgressIndicator()),
                ],
                error: (error, stack) => [Text(l10n.errorGeneric)],
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _sections(BuildContext context, FamilyOverview data) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    return [
      if (data.isEmpty) Text(l10n.familyEmpty, style: textTheme.bodyLarge),
      ..._seeMeSection(context, data),
      ..._iSeeSection(context, data),
      ..._wardsSection(context, data),
    ];
  }

  /// "Видят меня": links on the own profiles and the invite button.
  List<Widget> _seeMeSection(BuildContext context, FamilyOverview data) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final selfId = ref.watch(selfProfileProvider).valueOrNull?.id;
    final features = ref.watch(accountFeaturesProvider).valueOrNull;
    final limitReached =
        features?.relativesLimitReached(data.activeRelatives) ?? false;
    return [
      FamilySectionHeader(l10n.familySeeMe),
      if (data.seeMe.isEmpty)
        Text(l10n.familySeeMeEmpty, style: textTheme.bodyMedium),
      for (final link in data.seeMe)
        OutgoingLinkTile(
          link: link,
          onTap: () => unawaited(context.push(AppRoutes.link(link.id))),
        ),
      const SizedBox(height: 8),
      if (limitReached)
        Text(
          l10n.relativesLimitReached(features?.relativesLimit ?? 0),
          key: const Key('relatives-limit'),
          style: textTheme.bodyMedium,
        )
      else if (selfId != null)
        OutlinedButton.icon(
          key: const Key('invite-self'),
          onPressed: () =>
              unawaited(context.push(AppRoutes.createInvite(selfId))),
          icon: const Icon(Icons.person_add_alt_1),
          label: Text(l10n.inviteRelative),
        ),
    ];
  }

  /// "Я вижу": other people's profiles and the accept button.
  List<Widget> _iSeeSection(BuildContext context, FamilyOverview data) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    return [
      FamilySectionHeader(l10n.familyISee),
      if (data.iSee.isEmpty)
        Text(l10n.familyISeeEmpty, style: textTheme.bodyMedium),
      for (final link in data.iSee)
        IncomingLinkTile(
          link: link,
          onOpen: () =>
              unawaited(context.push(AppRoutes.profileToday(link.profileId))),
          onSettings: () => unawaited(context.push(AppRoutes.link(link.id))),
        ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const Key('accept-invite'),
        onPressed: () => unawaited(context.push(AppRoutes.acceptInvite)),
        icon: const Icon(Icons.link),
        label: Text(l10n.acceptInvite),
      ),
    ];
  }

  /// "Подопечные": managed profiles and the add button.
  List<Widget> _wardsSection(BuildContext context, FamilyOverview data) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    return [
      FamilySectionHeader(l10n.familyWards),
      if (data.wards.isEmpty)
        Text(l10n.familyWardsEmpty, style: textTheme.bodyMedium),
      for (final ward in data.wards)
        WardTile(
          access: ward,
          onOpen: () =>
              unawaited(context.push(AppRoutes.profileToday(ward.id))),
          onEdit: ward.canEditProfile
              ? () => unawaited(context.push(AppRoutes.managedProfile(ward.id)))
              : null,
        ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const Key('add-ward'),
        onPressed: () => unawaited(context.push(AppRoutes.newManagedProfile)),
        icon: const Icon(Icons.add),
        label: Text(l10n.addWard),
      ),
    ];
  }
}
