import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/relatives_dto.dart';
import '../../data/providers.dart';
import '../../links/link_providers.dart';
import '../../theme/app_theme.dart';
import '../../theme/radius.dart';
import '../../theme/shadows.dart';
import '../../theme/spacing.dart';
import '../common/formatters.dart';
import '../common/gap.dart';
import '../common/local_time.dart';
import '../common/stacked_buttons.dart';
import '../common/status_kind.dart';
import '../common/status_pill.dart';

/// An invite that lives at most this long shows its expiry hour as well.
const Duration _showTimeWithin = Duration(days: 1);

String _two(int value) => value.toString().padLeft(2, '0');

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
    final expiry = wallClockOf(invite.expiresAt, tz);
    // A short invite (a guardian's, 24 h) says the hour too: a date alone
    // would not tell tonight from tomorrow.
    final soon = invite.expiresAt.difference(ref.watch(clockProvider)()) <=
        _showTimeWithin;
    final day = formatLongDate(expiry.date, locale);
    final until =
        soon ? '$day, ${_two(expiry.hour)}:${_two(expiry.minute)}' : day;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.inviteReadyTitle,
          style: textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const Gap.v(PillPalSpacing.sm),
        Text(
          l10n.inviteReadyHint,
          style: textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        const Gap.v(PillPalSpacing.xl),
        Center(child: _QrFrame(data: invite.url, label: l10n.inviteQrLabel)),
        const Gap.v(PillPalSpacing.lg),
        Center(
          child: StatusPill(
            StatusKind.due,
            key: const Key('invite-valid-until'),
            label: l10n.inviteValidUntil(until),
          ),
        ),
        const Gap.v(PillPalSpacing.xl),
        StackedButtons(
          children: [
            FilledButton.icon(
              key: const Key('invite-share'),
              onPressed: () => unawaited(_share(ref, l10n)),
              icon: const Icon(Icons.share),
              label: Text(l10n.inviteShare),
            ),
            OutlinedButton(
              key: const Key('invite-done'),
              onPressed: onDone,
              child: Text(l10n.done),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _share(WidgetRef ref, AppLocalizations l10n) {
    return ref.read(textSharerProvider)(l10n.inviteShareText(invite.url));
  }
}

/// The code in a white frame with level-2 elevation (B2-README sizes: 220 in
/// a 20 px frame). The frame is white in every theme, so the quiet zone keeps
/// the code scannable in dark mode.
class _QrFrame extends StatelessWidget {
  const _QrFrame({required this.data, required this.label});

  final String data;
  final String label;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white, // ui-literal-ok: scanner contrast
        borderRadius: PillPalRadius.hero,
        boxShadow: PillPalShadows.forBrightness(
          Theme.of(context).brightness,
          PillPalShadows.level2,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(PillPalSpacing.xl),
        child: QrImageView(
          key: const Key('invite-qr'),
          data: data,
          size: PillPalSizes.qrCode,
          backgroundColor: Colors.white, // ui-literal-ok: scanner contrast
          semanticsLabel: label,
        ),
      ),
    );
  }
}
