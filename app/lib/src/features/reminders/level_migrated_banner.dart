import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../reminders/providers.dart';
import '../../theme/spacing.dart';
import '../common/pillpal_banner.dart';

/// Tells once, after an upgrade, that the reminder level is now the same for
/// all medications and where to change it (redesign Q2). Nothing when there
/// is nothing to tell.
class LevelMigratedBanner extends ConsumerWidget {
  /// Creates the banner.
  const LevelMigratedBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!(ref.watch(reminderLevelMigratedProvider).valueOrNull ?? false)) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: PillPalSpacing.lg),
      child: PillPalBanner(
        key: const Key('reminder-level-migrated'),
        icon: Icons.notifications_none,
        body: l10n.reminderLevelMigrated,
        actionsAlignment: WrapAlignment.end,
        actions: [
          TextButton(
            key: const Key('reminder-level-migrated-dismiss'),
            onPressed: () => unawaited(
              ref
                  .read(reminderSettingsRepositoryProvider)
                  .dismissLevelMigrationNotice(),
            ),
            child: Text(l10n.gotIt),
          ),
        ],
      ),
    );
  }
}
