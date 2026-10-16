import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../routing/routes.dart';
import '../../theme/palette.dart';
import 'auth_flow.dart';
import 'auth_session.dart';
import 'auth_widgets.dart';

/// First launch: confirm the data region, then register or sign in.
///
/// The region is suggested from the device locale (TZ §1). Only e-mail and
/// password exist for now (OAuth is Phase 5), which is also the only option
/// RU-iOS will ever have.
class WelcomeScreen extends ConsumerWidget {
  /// Creates the screen.
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final flow = ref.watch(authFlowProvider);
    final controller = ref.read(authFlowProvider.notifier);
    final selected =
        flow.region ?? DataRegion.suggestedFor(Localizations.localeOf(context));
    final sessionEnded =
        ref.watch(hasBoundLocalDataProvider).valueOrNull ?? false;
    void confirm(String route) {
      controller.confirmRegion(selected);
      context.push(route);
    }

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
        Text(l10n.regionQuestion,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        _RegionCard(
          key: const Key('region-ru'),
          title: l10n.regionRu,
          hint: l10n.regionRuHint,
          selected: selected == DataRegion.ru,
          onTap: () => controller.confirmRegion(DataRegion.ru),
        ),
        const SizedBox(height: 10),
        _RegionCard(
          key: const Key('region-eu'),
          title: l10n.regionEu,
          hint: l10n.regionEuHint,
          selected: selected == DataRegion.eu,
          onTap: () => controller.confirmRegion(DataRegion.eu),
        ),
        const SizedBox(height: 12),
        Text(l10n.regionNote, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 28),
        FilledButton(
          key: const Key('welcome-register'),
          onPressed: () => confirm(AppRoutes.register),
          child: Text(l10n.createAccount),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          key: const Key('welcome-login'),
          onPressed: () => confirm(AppRoutes.login),
          child: Text(l10n.haveAccount),
        ),
      ],
    );
  }
}

class _RegionCard extends StatelessWidget {
  const _RegionCard({
    required this.title,
    required this.hint,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String title;
  final String hint;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: palette.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: selected ? palette.action : palette.border,
            width: 2,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  color: selected ? palette.action : palette.inkMuted,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: textTheme.titleMedium),
                      const SizedBox(height: 2),
                      Text(hint, style: textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
