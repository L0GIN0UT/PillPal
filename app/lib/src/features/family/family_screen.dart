import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../routing/routes.dart';
import '../../theme/app_theme.dart';
import '../../theme/spacing.dart';
import '../common/banner_tone.dart';
import '../common/gap.dart';
import '../common/now_ticker.dart';
import '../common/pillpal_banner.dart';
import '../shell/empty_state.dart';
import 'day_status_providers.dart';
import 'family_header.dart';
import 'family_overview.dart';
import 'family_providers.dart';
import 'family_tiles.dart';
import 'new_relative_banner.dart';
import 'push_unavailable_hint.dart';

/// The Family tab (TZ §2.5; boards B-Family and B2-EmptyFamily): one list
/// «Близкие» with a row per person or managed profile, whatever links tie
/// us (docs/adr/0020 §4). Works from the stored links and notes, so it
/// opens offline; they are refreshed on open and after each sync.
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
  late final NowTicker _ticker = ref.read(nowTickerProvider);

  @override
  void initState() {
    super.initState();
    // A dose turns "missed" with time alone: the day pills re-read "now".
    _ticker.attach();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(ref.read(familyActionsProvider).refresh());
      }
    });
  }

  @override
  void dispose() {
    _ticker.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final overview = ref.watch(familyOverviewProvider);
    final data = overview.valueOrNull;
    final features = ref.watch(accountFeaturesProvider).valueOrNull;
    final limitReached = data != null &&
        (features?.relativesLimitReached(data.activeRelatives) ?? false);
    // «Добавить близкого»: my code, the scanner and «Веду сам». At the limit
    // the accept entry below still leads to the scanner.
    final invite = limitReached
        ? null
        : () => unawaited(context.push(AppRoutes.addRelative));
    // Non-null at the relatives limit: what the notice says.
    final reachedLimit = limitReached ? features?.relativesLimit ?? 0 : null;
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
                onInvite: data == null || data.isEmpty ? null : invite,
              ),
              const Gap.v(PillPalSpacing.lg),
              const NewRelativeBanner(),
              const PushUnavailableHint(),
              ...overview.when(
                skipLoadingOnReload: true,
                data: (data) => _sections(
                  context,
                  data,
                  invite: invite,
                  reachedLimit: reachedLimit,
                ),
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

  List<Widget> _sections(
    BuildContext context,
    FamilyOverview data, {
    required VoidCallback? invite,
    required int? reachedLimit,
  }) {
    if (data.isEmpty) {
      return [_emptyState(context, invite: invite, reachedLimit: reachedLimit)];
    }
    final l10n = AppLocalizations.of(context);
    return [
      for (final relative in data.relatives) _relativeRow(relative),
      if (reachedLimit != null) _limitNotice(context, reachedLimit),
      const Gap.v(PillPalSpacing.sm),
      OutlinedButton.icon(
        key: const Key('add-ward'),
        onPressed: _addWard,
        icon: const Icon(Icons.add),
        label: Text(l10n.addRelativeManaged),
      ),
      const Gap.v(PillPalSpacing.listGap),
      OutlinedButton.icon(
        key: const Key('accept-invite'),
        onPressed: _acceptInvite,
        icon: const Icon(Icons.link),
        label: Text(l10n.acceptInvite),
      ),
      const Gap.v(PillPalSpacing.lg),
      PillPalBanner(
        key: const Key('family-privacy-note'),
        tone: BannerTone.info,
        body: l10n.familyPrivacyNote,
      ),
    ];
  }

  /// One relative: tapping opens their day when I see it (their card
  /// otherwise), the pencil opens the card.
  Widget _relativeRow(Relative relative) {
    final card = AppRoutes.relative(relative.key);
    final day = relative.dayProfileId;
    return Padding(
      padding: const EdgeInsets.only(bottom: PillPalSpacing.listGap),
      child: Consumer(
        builder: (context, ref, _) => RelativeTile(
          relative: relative,
          dayStatus:
              day == null ? null : ref.watch(profileDayStatusProvider(day)),
          onOpen: () => unawaited(
            context.push(day == null ? card : AppRoutes.profileToday(day)),
          ),
          onEdit: () => unawaited(context.push(card)),
        ),
      ),
    );
  }

  /// Nobody yet (B2-EmptyFamily): invite or add a ward. Accepting an invite
  /// stays a quiet third entry under the card.
  Widget _emptyState(
    BuildContext context, {
    required VoidCallback? invite,
    required int? reachedLimit,
  }) {
    final l10n = AppLocalizations.of(context);
    return Column(
      children: [
        // At least the height of a card, never a fixed height: at large text
        // the actions must not be cut off below it.
        ConstrainedBox(
          constraints: const BoxConstraints(
            minHeight: PillPalSizes.emptyStateMinHeight,
          ),
          child: Center(
            // The empty state scrolls itself, which would swallow the pull
            // to refresh of the list: it has the whole list to grow in.
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(physics: const NeverScrollableScrollPhysics()),
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
                        label: Text(l10n.addRelativeTitle),
                      ),
                secondaryAction: OutlinedButton.icon(
                  key: const Key('add-ward'),
                  onPressed: _addWard,
                  icon: const Icon(Icons.add),
                  label: Text(l10n.addRelativeManaged),
                ),
              ),
            ),
          ),
        ),
        // A limit of 0 is the only way to be at the limit with nobody listed.
        if (reachedLimit != null) _limitNotice(context, reachedLimit),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: PillPalSpacing.xl),
          child: OutlinedButton.icon(
            key: const Key('accept-invite'),
            onPressed: _acceptInvite,
            icon: const Icon(Icons.link),
            label: Text(l10n.acceptInvite),
          ),
        ),
      ],
    );
  }

  Widget _limitNotice(BuildContext context, int limit) => Padding(
        padding: const EdgeInsets.only(bottom: PillPalSpacing.lg),
        child: PillPalBanner(
          key: const Key('relatives-limit'),
          tone: BannerTone.info,
          body: AppLocalizations.of(context).relativesLimitReached(limit),
        ),
      );

  void _addWard() => unawaited(context.push(AppRoutes.newManagedProfile));

  void _acceptInvite() => unawaited(context.push(AppRoutes.acceptInvite));
}
