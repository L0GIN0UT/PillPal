import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../push/push_providers.dart';
import '../../push/push_service.dart';
import '../../theme/palette.dart';

/// Tells the user that this phone cannot receive alerts about relatives: no
/// push service (no Google services with a Firebase project, no RuStore).
/// Shown only when alerts are needed (ADR 0008 §1), so it never nags an
/// account that has no relatives. Everything else keeps working: the day
/// view of a relative is current after a sync.
class PushUnavailableHint extends ConsumerWidget {
  /// Creates the hint.
  const PushUnavailableHint({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(pushStatusProvider);
    if (status.availability != PushAvailability.unavailable) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        key: const Key('push-unavailable-hint'),
        color: palette.actionSoft,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.pushUnavailableTitle,
                style: textTheme.titleMedium?.copyWith(
                  color: palette.onActionSoft,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.pushUnavailableBody,
                style: textTheme.bodyMedium?.copyWith(
                  color: palette.onActionSoft,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
