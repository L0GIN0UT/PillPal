import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/palette.dart';
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
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    final names = fresh
        .map((link) => link.counterpartName ?? l10n.relativeUnnamed)
        .join(', ');
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        key: const Key('new-relative-banner'),
        color: palette.actionSoft,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _title(context, l10n.newRelativeTitle(fresh.length)),
              const SizedBox(height: 8),
              Text(
                names,
                style: textTheme.bodyLarge?.copyWith(
                  color: palette.onActionSoft,
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  key: const Key('new-relative-dismiss'),
                  onPressed: () =>
                      unawaited(ref.read(familyActionsProvider).markSeen()),
                  child: Text(l10n.gotIt),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _title(BuildContext context, String text) {
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    return Row(
      children: [
        Icon(Icons.person_add_alt_1, color: palette.onActionSoft),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: textTheme.titleMedium?.copyWith(
              color: palette.onActionSoft,
            ),
          ),
        ),
      ],
    );
  }
}
