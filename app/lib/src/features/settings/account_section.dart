import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/api_exception.dart';
import '../../data/providers.dart';
import '../../data/sync/sync_status.dart';
import '../../routing/routes.dart';
import '../../theme/app_theme.dart';
import '../../theme/spacing.dart';
import '../auth/auth_session.dart';
import '../common/formatters.dart';
import '../common/gap.dart';
import '../common/list_row.dart';
import '../common/local_time.dart';
import '../common/pillpal_dialog.dart';
import '../common/show_pillpal_dialog.dart';
import '../common/text_fit.dart';

/// Outbox entries waiting to be pushed.
final pendingChangesProvider = StreamProvider<int>(
  (ref) => ref.watch(syncEngineProvider).watchPendingCount(),
);

/// Sync status line, pending count and a "sync now" button; the content of a
/// row of the «Приватность и данные» card, so it pads itself.
class SyncSection extends ConsumerWidget {
  /// Creates the section.
  const SyncSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final status = ref.watch(syncStatusProvider);
    final pending = ref.watch(pendingChangesProvider).valueOrNull ?? 0;
    return Padding(
      padding: PillPalSpacing.card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.syncTitle, style: textTheme.rowTitle),
          const Gap.v(PillPalSpacing.xs),
          Text(
            syncStatusText(context, ref, status),
            key: const Key('sync-status'),
            style: textTheme.bodySmall,
          ),
          if (pending > 0)
            Text(
              l10n.syncPending(pending),
              key: const Key('sync-pending'),
              style: textTheme.bodySmall,
            ),
          if (status.parkedCount > 0)
            Text(
              l10n.syncParked(status.parkedCount),
              style: textTheme.bodySmall,
            ),
          const Gap.v(PillPalSpacing.md),
          LayoutBuilder(
            builder: (context, constraints) {
              final onPressed = status.phase == SyncPhase.syncing
                  ? null
                  : () => requestSync(ref);
              final label = Text(l10n.syncNow);
              // Without the icon where the label would break inside the
              // word beside it (a narrow screen, large text).
              final withIcon = wordsFit(
                context,
                constraints.maxWidth -
                    2 * PillPalSpacing.xxl -
                    PillPalSizes.iconInline -
                    PillPalSpacing.sm,
                [(l10n.syncNow, Theme.of(context).textTheme.labelLarge)],
              );
              return withIcon
                  ? OutlinedButton.icon(
                      key: const Key('sync-now'),
                      onPressed: onPressed,
                      icon: const Icon(Icons.sync),
                      label: label,
                    )
                  : OutlinedButton(
                      key: const Key('sync-now'),
                      onPressed: onPressed,
                      child: label,
                    );
            },
          ),
        ],
      ),
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

/// «Сменить пароль»: a row of the account card (Settings leaves it out for an
/// account without a password).
class ChangePasswordRow extends StatelessWidget {
  /// Creates the row.
  const ChangePasswordRow({super.key});

  @override
  Widget build(BuildContext context) {
    return PillPalListRow(
      key: const Key('settings-change-password'),
      title: AppLocalizations.of(context).changePasswordTitle,
      leadingIcon: Icons.lock_outline,
      onTap: () => unawaited(context.push(AppRoutes.changePassword)),
    );
  }
}

/// "Выйти": a row of the account card that asks for confirmation. Signing
/// out is not destructive, so the row is not `danger`; only unsent changes
/// turn its dialog into a danger one.
class SignOutButton extends ConsumerWidget {
  /// Creates the button.
  const SignOutButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return PillPalListRow(
      key: const Key('sign-out'),
      title: l10n.signOut,
      leadingIcon: Icons.logout,
      onTap: () => unawaited(confirmSignOut(context, ref)),
    );
  }
}

/// Asks whether to sign out, then does it (or syncs first). [title] and
/// [body] replace the plain texts when another screen leads here, such as the
/// change of the password that points to «Forgot password?».
///
/// With [keepLocalData] the sign-out only ends the session (as a forced
/// sign-out does): the data and its binding to the account stay, so the same
/// account can sign in again and push its outbox. Nothing is lost then, so no
/// unsent-changes warning is shown.
///
/// With [syncPaused] (the consent gate: the medical sync is paused) signing
/// out keeps the data and its binding to the account, like a forced sign-out:
/// the paused changes are sent after the same account signs in and consents.
/// A second, destructive choice erases the data of this device. There is no
/// "sync first" choice, because it could not send anything.
Future<void> confirmSignOut(
  BuildContext context,
  WidgetRef ref, {
  String? title,
  String? body,
  bool keepLocalData = false,
  bool syncPaused = false,
}) async {
  final pending =
      keepLocalData ? 0 : await ref.read(pendingChangesProvider.future);
  if (!context.mounted) {
    return;
  }
  final choice = await showPillPalDialog<_SignOutChoice>(
    context: context,
    builder: (dialogContext) => _signOutDialog(
      dialogContext,
      pending: pending,
      title: title,
      body: body,
      syncPaused: syncPaused,
    ),
  );
  final session = ref.read(authSessionProvider.notifier);
  switch (choice) {
    case _SignOutChoice.signOut:
      await (keepLocalData || syncPaused
          ? session.signOutKeepingData()
          : session.signOut());
    case _SignOutChoice.signOutEraseData:
      await session.signOut();
    case _SignOutChoice.syncFirst:
      await ref.read(syncTriggerProvider)();
    case _SignOutChoice.cancel:
    case null:
      return;
  }
}

Widget _signOutDialog(
  BuildContext context, {
  required int pending,
  required bool syncPaused,
  String? title,
  String? body,
}) {
  final l10n = AppLocalizations.of(context);
  void close(_SignOutChoice choice) => Navigator.of(context).pop(choice);
  if (syncPaused) {
    return _pausedSignOutDialog(context, pending: pending);
  }
  return PillPalDialog(
    title: title ?? l10n.signOutTitle,
    // Unsent changes: the warning comes with the custom text, not instead.
    body: pending > 0
        ? [if (body != null) body, l10n.signOutPendingBody(pending)]
            .join('\n\n')
        : body ?? l10n.signOutBody,
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
      // Unsent changes are erased with the local data: offer to push them
      // first.
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
}

/// The sign-out of the consent gate: keeping the data is the default, erasing
/// it the explicit, destructive second choice.
Widget _pausedSignOutDialog(BuildContext context, {required int pending}) {
  final l10n = AppLocalizations.of(context);
  void close(_SignOutChoice choice) => Navigator.of(context).pop(choice);
  return PillPalDialog(
    title: l10n.signOutTitle,
    body: pending > 0
        ? '${l10n.signOutPausedKeepBody}\n\n'
            '${l10n.signOutPausedBody(pending)}'
        : l10n.signOutPausedKeepBody,
    choices: [
      DialogChoice(
        key: const Key('confirm-sign-out'),
        label: l10n.signOut,
        kind: DialogChoiceKind.primary,
        onPressed: () => close(_SignOutChoice.signOut),
      ),
      DialogChoice(
        key: const Key('sign-out-erase'),
        label: l10n.signOutEraseData,
        kind: DialogChoiceKind.destructive,
        onPressed: () => close(_SignOutChoice.signOutEraseData),
      ),
      DialogChoice(
        key: const Key('sign-out-cancel'),
        label: l10n.cancel,
        onPressed: () => close(_SignOutChoice.cancel),
      ),
    ],
  );
}

enum _SignOutChoice { cancel, syncFirst, signOut, signOutEraseData }
