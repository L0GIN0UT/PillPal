import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/api_exception.dart';
import '../../data/providers.dart';
import '../../data/sync/sync_status.dart';
import '../../theme/spacing.dart';
import '../auth/auth_session.dart';
import '../common/formatters.dart';
import '../common/gap.dart';
import '../common/group_label.dart';
import '../common/local_time.dart';
import '../common/pillpal_dialog.dart';

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
        GroupLabel(l10n.syncTitle),
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
        const Gap.v(PillPalSpacing.sm),
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
        return PillPalDialog(
          title: l10n.signOutTitle,
          body:
              pending > 0 ? l10n.signOutPendingBody(pending) : l10n.signOutBody,
          // Only unsent changes make signing out a loss.
          destructive: pending > 0,
          choices: [
            DialogChoice(
              key: const Key('confirm-sign-out'),
              label: l10n.signOut,
              kind: pending > 0
                  ? DialogChoiceKind.destructive
                  : DialogChoiceKind.primary,
              onPressed: () => close(_SignOutChoice.signOut),
            ),
            // Unsent changes are erased with the local data: offer to push
            // them first.
            if (pending > 0)
              DialogChoice(
                key: const Key('sign-out-sync-first'),
                label: l10n.syncNow,
                kind: DialogChoiceKind.primary,
                onPressed: () => close(_SignOutChoice.syncFirst),
              ),
            DialogChoice(
              key: const Key('sign-out-cancel'),
              label: l10n.cancel,
              onPressed: () => close(_SignOutChoice.cancel),
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
