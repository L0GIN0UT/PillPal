import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../routing/routes.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/radius.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import 'auth_session.dart';
import 'auth_widgets.dart';

/// First launch: the brand, a headline and the two ways in (B2 board
/// Welcome). The primary and secondary buttons are pinned to the bottom.
///
/// A build serves exactly one region (`PILLPAL_REGION`, TZ §1, §5), so the
/// screen shows no region card, choice or other-region note until the choice
/// exists (owner answer Q5, plan step A4). Only e-mail and password exist for
/// now; OAuth buttons come with their client ids (Q4).
class WelcomeScreen extends ConsumerWidget {
  /// Creates the screen.
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final sessionEnded =
        ref.watch(hasBoundLocalDataProvider).valueOrNull ?? false;
    return AuthScaffold(
      title: l10n.welcomeHeadline,
      subtitle: l10n.welcomeTagline,
      showBack: false,
      header: const _Brand(),
      actions: [
        FilledButton(
          key: const Key('welcome-register'),
          onPressed: () => context.push(AppRoutes.register),
          child: Text(l10n.createAccount),
        ),
        OutlinedButton(
          key: const Key('welcome-login'),
          onPressed: () => context.push(AppRoutes.login),
          child: Text(l10n.haveAccount),
        ),
      ],
      children: [
        if (sessionEnded)
          AuthNotice(
            key: const Key('session-ended'),
            text: l10n.sessionEndedNotice,
          ),
      ],
    );
  }
}

/// The app mark and its name above the headline. The gap to the headline
/// belongs to the scaffold.
///
/// TODO(owner): replace the placeholder icon with the real logo asset.
class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: PillPalSpacing.lg),
      child: Column(
        children: [
          Row(
            children: [
              // Decorative: the name beside it says what the app is.
              ExcludeSemantics(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: palette.action,
                    borderRadius: PillPalRadius.control,
                  ),
                  child: SizedBox.square(
                    dimension: PillPalSizes.avatarMd,
                    child: Icon(
                      Icons.medication_outlined,
                      color: palette.onAction,
                    ),
                  ),
                ),
              ),
              const Gap.h(PillPalSpacing.md),
              Expanded(
                child: Text(
                  l10n.welcomeTitle,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
