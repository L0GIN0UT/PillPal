import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/api_exception.dart';
import '../../data/providers.dart';
import '../../data/sync/sync_status.dart';
import '../auth/auth_session.dart';
import '../common/formatters.dart';
import '../common/local_time.dart';

/// Outbox entries waiting to be pushed.
final pendingChangesProvider = StreamProvider<int>(
  (ref) => ref.watch(syncEngineProvider).watchPendingCount(),
);

/// Sync status line, pending count and a "sync now" button.
class SyncSection extends ConsumerWidget {
  /// Creates the section.
  const SyncSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final status = ref.watch(syncStatusProvider);
    final pending = ref.watch(pendingChangesProvider).valueOrNull ?? 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.syncTitle, style: textTheme.titleSmall),
        const SizedBox(height: 8),
        Text(
          syncStatusText(context, ref, status),
          key: const Key('sync-status'),
          style: textTheme.bodyLarge,
        ),
        if (pending > 0)
          Text(
            l10n.syncPending(pending),
            key: const Key('sync-pending'),
            style: textTheme.bodySmall,
          ),
        if (status.parkedCount > 0)
          Text(l10n.syncParked(status.parkedCount), style: textTheme.bodySmall),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('sync-now'),
          onPressed:
              status.phase == SyncPhase.syncing ? null : () => requestSync(ref),
          icon: const Icon(Icons.sync),
          label: Text(l10n.syncNow),
        ),
      ],
    );
  }
}

/// "Синхронизировано в 14:05" / "Синхронизация…" / the error.
String syncStatusText(BuildContext context, WidgetRef ref, SyncStatus status) {
  final l10n = AppLocalizations.of(context);
  switch (status.phase) {
    case SyncPhase.syncing:
      return l10n.syncRunning;
    case SyncPhase.error:
      switch (status.errorCode) {
        case ApiException.networkError:
          return l10n.syncErrorNetwork;
        case ApiException.accountChanged:
          return l10n.syncErrorAccountChanged;
        default:
          return l10n.syncErrorGeneric;
      }
    case SyncPhase.idle:
      final last = status.lastSuccessAt;
      if (last == null) {
        return l10n.syncNever;
      }
      final tz = ref.watch(deviceTimeZoneProvider);
      final wall = wallClockOf(last, tz);
      final today = localDateOf(ref.watch(nowProvider), tz);
      if (wall.date == today) {
        return l10n.syncedAt(wall.hhmm);
      }
      final locale = Localizations.localeOf(context).toLanguageTag();
      return l10n.syncedOn(formatShortDate(wall.date, locale), wall.hhmm);
  }
}

/// Reminder defaults; the levels arrive with notifications in milestone 2.3
/// (docs/phase2-plan.md).
class NotificationDefaultsSection extends StatelessWidget {
  /// Creates the section.
  const NotificationDefaultsSection({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.notificationsTitle,
          style: Theme.of(context).textTheme.titleSmall,
        ),
        ListTile(
          key: const Key('notifications-level'),
          enabled: false,
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.notifications_outlined),
          title: Text(l10n.notificationsLevel),
          subtitle: Text(l10n.notificationsSoon),
        ),
      ],
    );
  }
}

/// "Выйти" with a confirmation dialog.
class SignOutButton extends ConsumerWidget {
  /// Creates the button.
  const SignOutButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return OutlinedButton.icon(
      key: const Key('sign-out'),
      onPressed: () => unawaited(_confirm(context, ref)),
      icon: const Icon(Icons.logout),
      label: Text(l10n.signOut),
    );
  }

  Future<void> _confirm(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final pending = ref.read(pendingChangesProvider).valueOrNull ?? 0;
    final choice = await showDialog<_SignOutChoice>(
      context: context,
      builder: (dialogContext) {
        void close(_SignOutChoice choice) =>
            Navigator.of(dialogContext).pop(choice);
        return AlertDialog(
          title: Text(l10n.signOutTitle),
          content: Text(
            pending > 0 ? l10n.signOutPendingBody(pending) : l10n.signOutBody,
          ),
          actions: [
            TextButton(
              onPressed: () => close(_SignOutChoice.cancel),
              child: Text(l10n.cancel),
            ),
            // Unsent changes are erased with the local data: offer to push
            // them first.
            if (pending > 0)
              TextButton(
                key: const Key('sign-out-sync-first'),
                onPressed: () => close(_SignOutChoice.syncFirst),
                child: Text(l10n.syncNow),
              ),
            TextButton(
              key: const Key('confirm-sign-out'),
              onPressed: () => close(_SignOutChoice.signOut),
              child: Text(l10n.signOut),
            ),
          ],
        );
      },
    );
    switch (choice) {
      case _SignOutChoice.signOut:
        await ref.read(authSessionProvider.notifier).signOut();
      case _SignOutChoice.syncFirst:
        await ref.read(syncTriggerProvider)();
      case _SignOutChoice.cancel:
      case null:
        return;
    }
  }
}

enum _SignOutChoice { cancel, syncFirst, signOut }
