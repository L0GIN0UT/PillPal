import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/radius.dart';
import '../../theme/shadows.dart';
import '../../theme/spacing.dart';
import '../common/clamped_text.dart';
import '../common/gap.dart';
import '../common/stacked_buttons.dart';
import '../common/status_kind.dart';
import '../common/status_pill.dart';
import 'invite_timing.dart';

/// What the code area of the invite panel shows.
enum InviteCodeArea {
  /// The code is being made.
  creating,

  /// The QR code of a live invite.
  code,

  /// The code ran out (or was revoked): a new one is offered.
  expired,
}

/// The QR code of an invite with its countdown, or the state in its place
/// (board B2-InviteReady). The link holds the token: it is drawn in the QR
/// code only, never as text, and leaves the app only through the share
/// sheet. [belowCode] (the role box of «Добавить близкого») sits under the
/// code in every state, so it keeps its place while a new code is made.
class InviteCodeView extends StatelessWidget {
  /// Creates the view.
  const InviteCodeView({
    required this.area,
    required this.url,
    required this.left,
    required this.onShare,
    required this.onRefresh,
    this.belowCode,
    super.key,
  });

  /// What the code area shows.
  final InviteCodeArea area;

  /// The invite link, while [area] is [InviteCodeArea.code].
  final String? url;

  /// The time left on the code.
  final Duration left;

  /// Hands the link to the share sheet.
  final VoidCallback onShare;

  /// Makes a new code after the old one ran out.
  final VoidCallback onRefresh;

  /// A control under the code.
  final Widget? belowCode;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final link = url;
    final extra = belowCode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClampedText(
          l10n.inviteCodeTitle,
          maxScale: PillPalSizes.titleMaxScale,
          style: textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        const Gap.v(PillPalSpacing.sm),
        Text(
          l10n.inviteCodeHint,
          style: textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        const Gap.v(PillPalSpacing.xl),
        // Scaled down, never cut, on a screen narrower than the frame (the
        // 280 px cover of a fold).
        Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: _QrFrame(
              child: switch (area) {
                InviteCodeArea.code when link != null => QrImageView(
                    key: const Key('invite-qr'),
                    data: link,
                    size: PillPalSizes.qrCode,
                    backgroundColor:
                        Colors.white, // ui-literal-ok: scanner contrast
                    semanticsLabel: l10n.inviteQrLabel,
                  ),
                InviteCodeArea.expired => const _Expired(),
                _ => const _Creating(),
              },
            ),
          ),
        ),
        const Gap.v(PillPalSpacing.lg),
        Center(child: _status(l10n)),
        if (extra != null) ...[
          const Gap.v(PillPalSpacing.lg),
          extra,
        ],
        const Gap.v(PillPalSpacing.lg),
        StackedButtons(
          children: [
            if (area == InviteCodeArea.expired)
              FilledButton.icon(
                key: const Key('invite-refresh'),
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh),
                label: Text(l10n.inviteCodeRefresh),
              )
            else
              FilledButton.icon(
                key: const Key('invite-share'),
                onPressed: area == InviteCodeArea.code ? onShare : null,
                icon: const Icon(Icons.share),
                label: Text(l10n.inviteShare),
              ),
          ],
        ),
      ],
    );
  }

  Widget _status(AppLocalizations l10n) {
    if (area == InviteCodeArea.expired) {
      return StatusPill(
        StatusKind.inactive,
        key: const Key('invite-expired'),
        label: l10n.inviteCodeExpired,
      );
    }
    // Not a live region: it would be read out every second.
    return StatusPill(
      StatusKind.due,
      key: const Key('invite-countdown'),
      label: l10n.inviteCodeTimeLeft(formatCountdown(left)),
    );
  }
}

/// The code in a white frame with level-2 elevation (B2-README sizes: 220 in
/// a 20 px frame). The frame is white in every theme, so the quiet zone keeps
/// the code scannable in dark mode.
class _QrFrame extends StatelessWidget {
  const _QrFrame({required this.child});

  final Widget child;

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
        child: SizedBox.square(dimension: PillPalSizes.qrCode, child: child),
      ),
    );
  }
}

class _Creating extends StatelessWidget {
  const _Creating();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: CircularProgressIndicator(key: Key('invite-creating')),
    );
  }
}

/// Where the code was: an icon on the white frame. The words are in the
/// status pill under it.
class _Expired extends StatelessWidget {
  const _Expired();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Icon(
        Icons.timer_off_outlined,
        size: PillPalSizes.iconEmpty,
        // The frame stays white in dark mode: the light ink reads on it.
        color: PillPalPalette.light.inkMuted,
      ),
    );
  }
}

/// The owner's confirmation that the code was scanned: «{name} теперь в
/// ваших близких», announced, with «Готово».
class RelativeAddedView extends StatelessWidget {
  /// Creates the view; [name] null when the new relative is not known yet.
  const RelativeAddedView({
    required this.name,
    required this.onDone,
    super.key,
  });

  /// The new relative's name.
  final String? name;

  /// Leaves the screen.
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final known = name;
    final title = known == null || known.isEmpty
        ? l10n.addRelativeSuccessUnnamed
        : l10n.addRelativeSuccess(known);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(
          Icons.check_circle_outline,
          size: PillPalSizes.iconEmpty,
          color: palette.taken,
        ),
        const Gap.v(PillPalSpacing.lg),
        Semantics(
          liveRegion: true,
          child: ClampedText(
            title,
            key: const Key('relative-added'),
            maxScale: PillPalSizes.titleMaxScale,
            style: Theme.of(context).textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
        ),
        const Gap.v(PillPalSpacing.xl),
        StackedButtons(
          children: [
            FilledButton(
              key: const Key('relative-added-done'),
              onPressed: onDone,
              child: Text(l10n.done),
            ),
          ],
        ),
      ],
    );
  }
}
