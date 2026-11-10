import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../routing/routes.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/banner_tone.dart';
import '../common/gap.dart';
import '../common/pillpal_banner.dart';
import '../common/section_header.dart';
import '../doses/dose_providers.dart';
import '../shell/empty_state.dart';
import 'family_header.dart';
import 'family_overview.dart';
import 'family_providers.dart';
import 'family_tiles.dart';
import 'new_relative_banner.dart';
import 'push_unavailable_hint.dart';

/// The Family tab (TZ §2.5; boards B-Family and B2-EmptyFamily): who I care
/// for, whose medications I see, and who sees mine, in that order. Works
/// from the stored links, so it opens offline; links are refreshed on open
/// and after each sync.
///
/// It lists every profile itself, so it has no profile switcher: choosing
/// a profile there would change nothing on the tab.
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
    final data = overview.valueOrNull;
    return Scaffold(
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () => ref.read(familyActionsProvider).refresh(),
          child: ListView(
            key: const Key('family-list'),
            physics: const AlwaysScrollableScrollPhysics(),
            padding: PillPalSpacing.tabHeader,
            children: [
              // The empty state carries its own invite button.
              FamilyHeader(
                onInvite: data == null || data.isEmpty ? null : _invite(data),
              ),
              const Gap.v(PillPalSpacing.lg),
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

  /// The invite action, or null at the relatives limit or before the own
  /// profile is known.
  VoidCallback? _invite(FamilyOverview data) {
    final selfId = ref.watch(selfProfileProvider).valueOrNull?.id;
    if (selfId == null || _limitReached(data)) {
      return null;
    }
    return () => unawaited(context.push(AppRoutes.createInvite(selfId)));
  }

  bool _limitReached(FamilyOverview data) =>
      ref
          .watch(accountFeaturesProvider)
          .valueOrNull
          ?.relativesLimitReached(data.activeRelatives) ??
      false;

  List<Widget> _sections(BuildContext context, FamilyOverview data) {
    if (data.isEmpty) {
      return [_emptyState(context, data)];
    }
    return [
      ..._wardsSection(context, data),
      ..._iSeeSection(context, data),
      ..._seeMeSection(context, data),
      const Gap.v(PillPalSpacing.lg),
      PillPalBanner(
        key: const Key('family-privacy-note'),
        tone: BannerTone.info,
        body: AppLocalizations.of(context).familyPrivacyNote,
      ),
    ];
  }

  /// Nobody yet (B2-EmptyFamily): invite or add a ward. Accepting an invite
  /// stays a quiet third entry under the card.
  Widget _emptyState(BuildContext context, FamilyOverview data) {
    final l10n = AppLocalizations.of(context);
    final invite = _invite(data);
    return Column(
      children: [
        // At least the height of a card, never a fixed height: at large text
        // the actions must not be cut off below it.
        ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: PillPalSizes.emptyStateMinHeight,
          ),
          child: Center(
            child: EmptyState(
              icon: Icons.people_outline,
              headline: l10n.familyEmptyTitle,
              message: l10n.familyEmpty,
              action: invite == null
                  ? null
                  : FilledButton.icon(
                      key: const Key('invite-self'),
                      onPressed: invite,
                      icon: const Icon(Icons.person_add_alt_1),
                      label: Text(l10n.inviteRelative),
                    ),
              secondaryAction: OutlinedButton.icon(
                key: const Key('add-ward'),
                onPressed: _addWard,
                icon: const Icon(Icons.add),
                label: Text(l10n.addWard),
              ),
            ),
          ),
        ),
        TextButton.icon(
          key: const Key('accept-invite'),
          onPressed: _acceptInvite,
          icon: const Icon(Icons.link),
          label: Text(l10n.acceptInvite),
        ),
      ],
    );
  }

  void _addWard() => unawaited(context.push(AppRoutes.newManagedProfile));

  void _acceptInvite() => unawaited(context.push(AppRoutes.acceptInvite));

  /// A card of a list with the gap below it (cards have no margin).
  Widget _listItem(Widget card) => Padding(
        padding: const EdgeInsets.only(bottom: PillPalSpacing.listGap),
        child: card,
      );

  /// What a section says while it has no rows.
  Widget _hint(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: PillPalSpacing.listGap),
        child: Text(
          text,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: context.palette.inkMuted),
        ),
      );

  /// "Подопечные": managed profiles and the add button.
  List<Widget> _wardsSection(BuildContext context, FamilyOverview data) {
    final l10n = AppLocalizations.of(context);
    return [
      SectionHeader(l10n.familyWards),
      if (data.wards.isEmpty) _hint(context, l10n.familyWardsEmpty),
      for (final ward in data.wards)
        _listItem(
          WardTile(
            access: ward,
            onOpen: () =>
                unawaited(context.push(AppRoutes.profileToday(ward.id))),
            onEdit: ward.canEditProfile
                ? () =>
                    unawaited(context.push(AppRoutes.managedProfile(ward.id)))
                : null,
          ),
        ),
      OutlinedButton.icon(
        key: const Key('add-ward'),
        onPressed: _addWard,
        icon: const Icon(Icons.add),
        label: Text(l10n.addWard),
      ),
    ];
  }

  /// "Я вижу": other people's profiles and the accept button.
  List<Widget> _iSeeSection(BuildContext context, FamilyOverview data) {
    final l10n = AppLocalizations.of(context);
    return [
      SectionHeader(l10n.familyISee),
      if (data.iSee.isEmpty) _hint(context, l10n.familyISeeEmpty),
      for (final link in data.iSee)
        _listItem(
          IncomingLinkTile(
            link: link,
            onOpen: () => unawaited(
              context.push(AppRoutes.profileToday(link.profileId)),
            ),
            onSettings: () => unawaited(context.push(AppRoutes.link(link.id))),
          ),
        ),
      OutlinedButton.icon(
        key: const Key('accept-invite'),
        onPressed: _acceptInvite,
        icon: const Icon(Icons.link),
        label: Text(l10n.acceptInvite),
      ),
    ];
  }

  /// "Видят меня": links on the own profiles. The invite button is in the
  /// header; at the limit a notice says why it is gone.
  List<Widget> _seeMeSection(BuildContext context, FamilyOverview data) {
    final l10n = AppLocalizations.of(context);
    final features = ref.watch(accountFeaturesProvider).valueOrNull;
    return [
      SectionHeader(l10n.familySeeMe),
      if (data.seeMe.isEmpty) _hint(context, l10n.familySeeMeEmpty),
      for (final link in data.seeMe)
        _listItem(
          OutgoingLinkTile(
            link: link,
            onTap: () => unawaited(context.push(AppRoutes.link(link.id))),
          ),
        ),
      if (_limitReached(data))
        PillPalBanner(
          key: const Key('relatives-limit'),
          tone: BannerTone.info,
          body: l10n.relativesLimitReached(features?.relativesLimit ?? 0),
        ),
    ];
  }
}
