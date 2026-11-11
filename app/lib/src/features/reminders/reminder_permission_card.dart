import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../reminders/notification_scheduler.dart';
import '../../reminders/providers.dart';
import '../../reminders/reminder_status.dart';
import '../common/banner_tone.dart';
import '../common/pillpal_banner.dart';

/// Onboarding / warning card for the Today screen (TZ §2.3, ADR 0001 §4,
/// §6): asks for the notification permission, then for exact alarms
/// (Android 12+), hints at the Time Sensitive switch when persistent or
/// alarm reminders cannot break through a Focus (iOS), and on phones known
/// to kill background work shows how to keep reminders alive. Renders
/// nothing when everything is fine. Each request re-plans, so the card
/// disappears once granted.
class ReminderPermissionCard extends ConsumerStatefulWidget {
  /// Creates the card.
  const ReminderPermissionCard({this.padding = EdgeInsets.zero, super.key});

  /// Space around the banner (nothing is added while there is no banner).
  final EdgeInsetsGeometry padding;

  @override
  ConsumerState<ReminderPermissionCard> createState() =>
      _ReminderPermissionCardState();
}

class _ReminderPermissionCardState
    extends ConsumerState<ReminderPermissionCard> {
  bool _batteryHintDone = false;
  bool _timeSensitiveHintDone = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final status = ref.watch(reminderStatusProvider);
    final permissions = status.permissions;
    final actions = ref.read(reminderPermissionActionsProvider);
    final banner = _banner(l10n, status, permissions, actions);
    return banner == null
        ? const SizedBox.shrink()
        : Padding(padding: widget.padding, child: banner);
  }

  Widget? _banner(
    AppLocalizations l10n,
    ReminderStatus status,
    ReminderPermissions permissions,
    ReminderPermissionActions actions,
  ) {
    if (!permissions.notificationsEnabled) {
      return _notice(
        key: const ValueKey('reminder-permission-notifications'),
        tone: BannerTone.danger,
        icon: Icons.notifications_off_outlined,
        title: l10n.reminderPermissionNotificationsTitle,
        body: l10n.reminderPermissionNotificationsBody,
        action: l10n.reminderPermissionAllow,
        onPressed: () => _request(actions.requestNotifications),
      );
    }
    if (!permissions.exactAlarmsAllowed) {
      return _notice(
        key: const ValueKey('reminder-permission-exact'),
        tone: BannerTone.soft,
        icon: Icons.alarm_off_outlined,
        title: l10n.reminderPermissionExactTitle,
        body: l10n.reminderPermissionExactBody,
        action: l10n.reminderPermissionOpenSettings,
        onPressed: () => _request(actions.requestExactAlarms),
      );
    }
    if (status.timeSensitiveDegraded && !_timeSensitiveHintDone) {
      return _notice(
        key: const ValueKey('reminder-time-sensitive-hint'),
        tone: BannerTone.soft,
        icon: Icons.notifications_paused_outlined,
        title: l10n.reminderTimeSensitiveTitle,
        body: l10n.reminderTimeSensitiveBody,
        action: l10n.reminderPermissionOpenSettings,
        onPressed: () => _request(actions.openNotificationSettings),
        secondaryAction: l10n.reminderBatteryDone,
        onSecondary: () => setState(() => _timeSensitiveHintDone = true),
      );
    }
    final vendor = ref.watch(batteryHintVendorProvider).valueOrNull;
    if (vendor != null && !_batteryHintDone) {
      return _notice(
        key: const ValueKey('reminder-battery-hint'),
        tone: BannerTone.soft,
        icon: Icons.battery_alert_outlined,
        title: l10n.reminderBatteryTitle,
        body: l10n.reminderBatteryBody(vendor),
        action: l10n.reminderPermissionOpenSettings,
        onPressed: () => _request(actions.openBatterySettings),
        secondaryAction: l10n.reminderBatteryDone,
        onSecondary: () => setState(() => _batteryHintDone = true),
      );
    }
    return null;
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

/// One banner of the card; [key] marks the banner itself.
Widget _notice({
  required Key key,
  required BannerTone tone,
  required IconData icon,
  required String title,
  required String body,
  required String action,
  required VoidCallback onPressed,
  String? secondaryAction,
  VoidCallback? onSecondary,
}) {
  return PillPalBanner(
    key: key,
    tone: tone,
    icon: icon,
    title: title,
    body: body,
    actions: [
      FilledButton(onPressed: onPressed, child: Text(action)),
      if (secondaryAction != null)
        TextButton(onPressed: onSecondary, child: Text(secondaryAction)),
    ],
  );
}
