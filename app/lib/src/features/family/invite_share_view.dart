import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/relatives_dto.dart';
import '../../links/link_providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/spacing.dart';
import '../common/formatters.dart';
import '../common/gap.dart';
import '../common/local_time.dart';

/// A created invite: the QR code and the system share sheet. The link holds
/// the token and is shown once, in the QR code only; it is never written to a
/// log or a URL, and leaving the screen forgets it.
class InviteShareView extends ConsumerWidget {
  /// Creates the view for [invite].
  const InviteShareView(
      {required this.invite, required this.onDone, super.key});

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
        const Gap.v(PillPalSpacing.sm),
        Text(l10n.inviteReadyHint, style: textTheme.bodyLarge),
        const Gap.v(PillPalSpacing.xl),
        Center(
          child: QrImageView(
            key: const Key('invite-qr'),
            data: invite.url,
            size: PillPalSizes.qrCode,
            // A white quiet zone keeps the code scannable in dark theme.
            backgroundColor: Colors.white, // ui-literal-ok: scanner contrast
            semanticsLabel: l10n.inviteQrLabel,
          ),
        ),
        const Gap.v(PillPalSpacing.md),
        Text(
          l10n.inviteValidUntil(formatLongDate(until, locale)),
          key: const Key('invite-valid-until'),
          style: textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        const Gap.v(PillPalSpacing.xl),
        FilledButton.icon(
          key: const Key('invite-share'),
          onPressed: () => unawaited(_share(ref, l10n)),
          icon: const Icon(Icons.share),
          label: Text(l10n.inviteShare),
        ),
        const Gap.v(PillPalSpacing.sm),
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
