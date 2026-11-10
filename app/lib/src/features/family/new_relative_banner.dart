import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/spacing.dart';
import '../common/pillpal_banner.dart';
import 'family_providers.dart';

/// Tells the owner that someone new sees their medications: relatives who
/// accepted an invite, or whose account was restored. It comes from the
/// stored links, so it appears without any push (ADR 0005 §3).
class NewRelativeBanner extends ConsumerWidget {
  /// Creates the banner.
  const NewRelativeBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fresh = ref.watch(newRelativesProvider);
    if (fresh.isEmpty) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final names = fresh
        .map((link) => link.counterpartName ?? l10n.relativeUnnamed)
        .join(', ');
    return Padding(
      padding: const EdgeInsets.only(bottom: PillPalSpacing.lg),
      child: PillPalBanner(
        key: const Key('new-relative-banner'),
        icon: Icons.person_add_alt_1,
        title: l10n.newRelativeTitle(fresh.length),
        body: names,
        actionsAlignment: WrapAlignment.end,
        actions: [
          TextButton(
            key: const Key('new-relative-dismiss'),
            onPressed: () =>
                unawaited(ref.read(familyActionsProvider).markSeen()),
            child: Text(l10n.gotIt),
          ),
        ],
      ),
    );
  }
}
