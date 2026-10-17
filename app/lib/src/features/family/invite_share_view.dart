import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/relatives_dto.dart';
import '../../links/link_providers.dart';
import '../common/formatters.dart';
import '../common/local_time.dart';

/// A created invite: the QR code and the system share sheet. The link holds
/// the token and is shown once, in the QR code only; it is never written to a
/// log or a URL, and leaving the screen forgets it.
class InviteShareView extends ConsumerWidget {
  /// Creates the view for [invite].
  const InviteShareView({required this.invite, required this.onDone, super.key});

  /// The invite just created.
  final InviteCreated invite;

  /// "Done": leaves the screen.
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final tz = ref.watch(deviceTimeZoneProvider);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final until = wallClockOf(invite.expiresAt, tz).date;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.inviteReadyTitle, style: textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(l10n.inviteReadyHint, style: textTheme.bodyLarge),
        const SizedBox(height: 20),
        Center(
          child: QrImageView(
            key: const Key('invite-qr'),
            data: invite.url,
            size: 240,
            // A white quiet zone keeps the code scannable in dark theme.
            backgroundColor: Colors.white,
            semanticsLabel: l10n.inviteQrLabel,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          l10n.inviteValidUntil(formatLongDate(until, locale)),
          key: const Key('invite-valid-until'),
          style: textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          key: const Key('invite-share'),
          onPressed: () => unawaited(_share(ref, l10n)),
          icon: const Icon(Icons.share),
          label: Text(l10n.inviteShare),
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('invite-done'),
          onPressed: onDone,
          child: Text(l10n.done),
        ),
      ],
    );
  }

  Future<void> _share(WidgetRef ref, AppLocalizations l10n) {
    return ref.read(textSharerProvider)(l10n.inviteShareText(invite.url));
  }
}
