import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/radius.dart';
import '../../theme/shadows.dart';
import '../../theme/spacing.dart';
import '../common/banner_tone.dart';
import '../common/clamped_text.dart';
import '../common/gap.dart';
import '../common/pillpal_banner.dart';
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

  /// The code could not be made: the reason and a new try.
  failed,
}

/// The colours inside the white QR frame: the light palette in every theme
/// (the frame stays white for the scanner), the senior one in senior mode.
PillPalPalette qrFramePalette(BuildContext context) => context.metrics.isSenior
    ? PillPalPalette.lightSenior
    : PillPalPalette.light;

/// The QR code of an invite with its countdown, or the state in its place
/// (board B2-InviteReady). The link holds the token: it is drawn in the QR
/// code only, never as text, and leaves the app only through the share
/// sheet. [belowCode] (the role box of «Добавить близкого») sits under the
/// code in every state; [secondaryAction] («Готово») joins the same stack
/// of buttons.
class InviteCodeView extends StatelessWidget {
  /// Creates the view.
  const InviteCodeView({
    required this.area,
    required this.url,
    required this.left,
    required this.onShare,
    required this.onRefresh,
    this.errorText,
    this.belowCode,
    this.secondaryAction,
    super.key,
  });

  /// What the code area shows.
  final InviteCodeArea area;

  /// The invite link, while [area] is [InviteCodeArea.code].
  final String? url;

  /// The time left on the code, read by the countdown each second.
  final Duration Function() left;

  /// Hands the link to the share sheet; null while that is not possible.
  final VoidCallback? onShare;

  /// Makes a new code (after it ran out or could not be made).
  final VoidCallback onRefresh;

  /// Why the code could not be made, for [InviteCodeArea.failed].
  final String? errorText;

  /// A control under the code.
  final Widget? belowCode;

  /// A second button under the main one.
  final Widget? secondaryAction;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final extra = belowCode;
    final second = secondaryAction;
    final renew =
        area == InviteCodeArea.expired || area == InviteCodeArea.failed;
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
        if (area == InviteCodeArea.failed)
          PillPalBanner(
            tone: BannerTone.danger,
            liveRegion: true,
            body: errorText ?? l10n.errorGeneric,
            bodyKey: const Key('invite-error'),
          )
        else ...[
          // Scaled down, never cut, on a screen narrower than the frame (the
          // 280 px cover of a fold).
          Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: _QrFrame(child: _frameContent(l10n)),
            ),
          ),
          const Gap.v(PillPalSpacing.lg),
          Center(
            child: area == InviteCodeArea.expired
                ? Semantics(
                    liveRegion: true,
                    child: StatusPill(
                      StatusKind.inactive,
                      key: const Key('invite-expired'),
                      label: l10n.inviteCodeExpired,
                    ),
                  )
                : InviteCountdown(left: left),
          ),
        ],
        if (extra != null) ...[
          const Gap.v(PillPalSpacing.lg),
          extra,
        ],
        const Gap.v(PillPalSpacing.lg),
        StackedButtons(
          children: [
            if (renew)
              FilledButton.icon(
                key: Key(
                  area == InviteCodeArea.failed
                      ? 'invite-retry'
                      : 'invite-refresh',
                ),
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
            if (second != null) second,
          ],
        ),
      ],
    );
  }

  Widget _frameContent(AppLocalizations l10n) {
    final link = url;
    if (area == InviteCodeArea.code && link != null) {
      return QrImageView(
        key: const Key('invite-qr'),
        data: link,
        size: PillPalSizes.qrCode,
        backgroundColor: Colors.white, // ui-literal-ok: scanner contrast
        semanticsLabel: l10n.inviteQrLabel,
      );
    }
    return area == InviteCodeArea.expired
        ? const _Expired()
        : const _Creating();
  }
}

/// «Код действует ещё N мин», seconds only in the last minute, in tabular
/// figures. It redraws itself each second, so the QR code above it does not.
/// Screen readers get minutes and seconds in words; it is not a live region
/// (it would be read out every second).
class InviteCountdown extends StatefulWidget {
  /// Creates the countdown of [left].
  const InviteCountdown({required this.left, super.key});

  /// The time left, read on every tick.
  final Duration Function() left;

  @override
  State<InviteCountdown> createState() => _InviteCountdownState();
}

class _InviteCountdownState extends State<InviteCountdown> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(InviteTiming.tick, (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final left = widget.left();
    final seconds = left.isNegative ? 0 : left.inSeconds;
    final minutes = seconds ~/ Duration.secondsPerMinute;
    final rest = seconds % Duration.secondsPerMinute;
    final text = seconds >= Duration.secondsPerMinute
        ? l10n.inviteCodeLeftMinutes(ceilMinutes(left))
        : l10n.inviteCodeLeftSeconds(seconds);
    final spoken = [
      if (minutes > 0) l10n.inviteCodeSpokenMinutes(minutes),
      if (rest > 0 || minutes == 0) l10n.inviteCodeSpokenSeconds(rest),
    ].join(' ');
    return Semantics(
      label: l10n.inviteCodeLeftSpoken(spoken),
      excludeSemantics: true,
      child: DefaultTextStyle.merge(
        style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
        child: StatusPill(
          StatusKind.pending,
          key: const Key('invite-countdown'),
          label: text,
        ),
      ),
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
    return Center(
      child: CircularProgressIndicator(
        key: const Key('invite-creating'),
        color: qrFramePalette(context).action,
      ),
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
        color: qrFramePalette(context).inkMuted,
      ),
    );
  }
}
