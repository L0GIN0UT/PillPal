import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/providers.dart';
import '../../routing/routes.dart';
import '../../theme/palette.dart';
import 'auth_session.dart';
import 'auth_widgets.dart';

/// First launch: where the data is stored, then register or sign in.
///
/// Until Phase 5 (regional routing) a build serves exactly one region
/// (`PILLPAL_REGION`, TZ §1, §5): the screen states it instead of offering a
/// choice, and explains when the device language suggests the other region.
/// Only e-mail and password exist for now (OAuth is Phase 5), which is also
/// the only option RU-iOS will ever have.
class WelcomeScreen extends ConsumerWidget {
  /// Creates the screen.
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final served = DataRegion.fromWire(ref.watch(apiConfigProvider).region);
    final suggested =
        DataRegion.suggestedFor(Localizations.localeOf(context));
    final sessionEnded =
        ref.watch(hasBoundLocalDataProvider).valueOrNull ?? false;
    return AuthScaffold(
      title: l10n.welcomeTitle,
      subtitle: l10n.welcomeTagline,
      showBack: false,
      children: [
        if (sessionEnded)
          AuthNotice(
            key: const Key('session-ended'),
            text: l10n.sessionEndedNotice,
          ),
        _RegionCard(region: served),
        if (suggested != served) ...[
          const SizedBox(height: 12),
          AuthNotice(
            key: const Key('region-other-later'),
            text: l10n.regionOtherLater(
              regionName(l10n, served),
              regionName(l10n, suggested),
            ),
          ),
        ] else
          const SizedBox(height: 12),
        Text(l10n.regionNote, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 28),
        FilledButton(
          key: const Key('welcome-register'),
          onPressed: () => context.push(AppRoutes.register),
          child: Text(l10n.createAccount),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          key: const Key('welcome-login'),
          onPressed: () => context.push(AppRoutes.login),
          child: Text(l10n.haveAccount),
        ),
      ],
    );
  }
}

/// Localized name of [region].
String regionName(AppLocalizations l10n, DataRegion region) =>
    switch (region) {
      DataRegion.ru => l10n.regionRu,
      DataRegion.eu => l10n.regionEu,
    };

/// "Your data will be stored in: Russia" with where the servers are.
class _RegionCard extends StatelessWidget {
  const _RegionCard({required this.region});

  final DataRegion region;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    final hint = switch (region) {
      DataRegion.ru => l10n.regionRuHint,
      DataRegion.eu => l10n.regionEuHint,
    };
    return Container(
      key: const Key('region-build'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: palette.border, width: 2),
      ),
      child: Row(
        children: [
          Icon(Icons.dns_outlined, color: palette.action),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.dataStoredIn(regionName(l10n, region)),
                  style: textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                Text(hint, style: textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
