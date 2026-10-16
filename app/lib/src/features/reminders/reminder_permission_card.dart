import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../reminders/providers.dart';

/// Onboarding / warning card for the Today screen (TZ §2.3, ADR 0001 §4):
/// asks for the notification permission, then for exact alarms (Android
/// 12+), and on phones known to kill background work shows how to keep
/// reminders alive. Renders nothing when everything is fine. Each request
/// re-plans, so the card disappears once granted.
class ReminderPermissionCard extends ConsumerStatefulWidget {
  /// Creates the card.
  const ReminderPermissionCard({super.key});

  @override
  ConsumerState<ReminderPermissionCard> createState() =>
      _ReminderPermissionCardState();
}

class _ReminderPermissionCardState
    extends ConsumerState<ReminderPermissionCard> {
  bool _batteryHintDone = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final status = ref.watch(reminderStatusProvider);
    final permissions = status.permissions;
    final actions = ref.read(reminderPermissionActionsProvider);
    if (!permissions.notificationsEnabled) {
      return _NoticeCard(
        key: const ValueKey('reminder-permission-notifications'),
        icon: Icons.notifications_off_outlined,
        title: l10n.reminderPermissionNotificationsTitle,
        body: l10n.reminderPermissionNotificationsBody,
        action: l10n.reminderPermissionAllow,
        onPressed: () => _request(actions.requestNotifications),
      );
    }
    if (!permissions.exactAlarmsAllowed) {
      return _NoticeCard(
        key: const ValueKey('reminder-permission-exact'),
        icon: Icons.alarm_off_outlined,
        title: l10n.reminderPermissionExactTitle,
        body: l10n.reminderPermissionExactBody,
        action: l10n.reminderPermissionOpenSettings,
        onPressed: () => _request(actions.requestExactAlarms),
      );
    }
    final vendor = ref.watch(batteryHintVendorProvider).valueOrNull;
    if (vendor != null && !_batteryHintDone) {
      return _NoticeCard(
        key: const ValueKey('reminder-battery-hint'),
        icon: Icons.battery_alert_outlined,
        title: l10n.reminderBatteryTitle,
        body: l10n.reminderBatteryBody(vendor),
        action: l10n.reminderPermissionOpenSettings,
        onPressed: () => _request(actions.openBatterySettings),
        secondaryAction: l10n.reminderBatteryDone,
        onSecondary: () => setState(() => _batteryHintDone = true),
      );
    }
    return const SizedBox.shrink();
  }

  void _request(Future<bool> Function() request) {
    // Read before the await: the card may be gone when the user returns.
    final refresh = ref.read(reminderRefreshProvider);
    unawaited(() async {
      await request();
      await refresh();
    }());
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.action,
    required this.onPressed,
    this.secondaryAction,
    this.onSecondary,
    super.key,
  });

  final IconData icon;
  final String title;
  final String body;
  final String action;
  final VoidCallback onPressed;
  final String? secondaryAction;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final secondary = secondaryAction;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: theme.colorScheme.error),
                const SizedBox(width: 12),
                Expanded(
                    child: Text(title, style: theme.textTheme.titleMedium)),
              ],
            ),
            const SizedBox(height: 8),
            Text(body),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(onPressed: onPressed, child: Text(action)),
                if (secondary != null)
                  TextButton(onPressed: onSecondary, child: Text(secondary)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
