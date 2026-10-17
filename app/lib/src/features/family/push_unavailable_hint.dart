import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../push/push_providers.dart';
import '../../push/push_service.dart';
import '../../reminders/providers.dart';
import '../../theme/palette.dart';

/// Tells the user that this phone will not show alerts about relatives, in two
/// cases: it has no push service (no Google services with a Firebase project,
/// no RuStore), or alerts arrive but notifications are off for the app in the
/// system settings (Android 13+ permission, iOS authorization). Shown only
/// when alerts are needed (ADR 0008 §1), so it never nags an account that has
/// no relatives. Everything else keeps working: the day view of a relative is
/// current after a sync.
class PushUnavailableHint extends ConsumerWidget {
  /// Creates the hint.
  const PushUnavailableHint({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(pushStatusProvider);
    final notificationsOff = ref.watch(
      reminderStatusProvider
          .select((reminders) => !reminders.permissions.notificationsEnabled),
    );
    final l10n = AppLocalizations.of(context);
    if (status.availability == PushAvailability.unavailable) {
      return _card(
        context,
        key: const Key('push-unavailable-hint'),
        title: l10n.pushUnavailableTitle,
        body: l10n.pushUnavailableBody,
      );
    }
    if (status.availability == PushAvailability.registered &&
        notificationsOff) {
      return _card(
        context,
        key: const Key('push-notifications-off-hint'),
        title: l10n.pushNotificationsOffTitle,
        body: l10n.pushNotificationsOffBody,
      );
    }
    return const SizedBox.shrink();
  }

  Widget _card(
    BuildContext context, {
    required Key key,
    required String title,
    required String body,
  }) {
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        key: key,
        color: palette.actionSoft,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: textTheme.titleMedium?.copyWith(
                  color: palette.onActionSoft,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                body,
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
