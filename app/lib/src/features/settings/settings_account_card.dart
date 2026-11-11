import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/auth_dto.dart';
import '../../data/providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import '../common/person_row.dart';
import '../common/pillpal_card.dart';

/// The signed-in account (`GET /v1/me`), or null while it is loading or when
/// the phone is offline: the card then says only that you are signed in, and
/// the account rows assume the usual case. Never logged and never stored
/// beyond this screen.
final settingsAccountProvider = FutureProvider.autoDispose<UserInfo?>((
  ref,
) async {
  try {
    return await ref.watch(authApiProvider).me();
  } on Object {
    // Offline, signed out or a malformed body: the card still renders.
    return null;
  }
});

/// The top card of Settings (board B2-Settings): an avatar with the initial of
/// the e-mail and the e-mail. The data region is not shown while it cannot be
/// chosen in the app (owner decision, as on registration). From the compact
/// text scale on the avatar goes away (B2-README 9.7), so the e-mail keeps the
/// width.
class SettingsAccountCard extends ConsumerWidget {
  /// Creates the card.
  const SettingsAccountCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final email = ref.watch(settingsAccountProvider).valueOrNull?.email;
    final compact =
        MediaQuery.textScalerOf(context).scale(1) >= PillPalSizes.compactScale;
    return MergeSemantics(
      child: PillPalCard(
        key: const Key('settings-account-card'),
        child: Row(
          children: [
            if (!compact) ...[
              PillPalAvatar(name: email ?? ''),
              const Gap.h(PillPalSpacing.md),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Two lines at most; the full address stays in semantics.
                  Text(
                    email ?? l10n.settingsAccountSignedIn,
                    key: const Key('settings-account-title'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.rowTitleStrong,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
