import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/radius.dart';
import '../../theme/spacing.dart';
import 'scanner_adapter.dart';

/// The camera view of the scan sheet (board B2-ScanCamera): a 300 high
/// card with the live preview, a frame of four corner marks and the torch
/// button. The preview is drawn over `scrim`, so the view is dark before the
/// camera starts and behind a camera that fails.
///
/// The marks and the torch icon use `onHero`, the light content colour of
/// the dark blocks, because they sit on a camera image, not on the page.
/// The sizes below are the board's; they are used here only.
class ScanViewfinder extends StatelessWidget {
  /// Creates the view of [preview]; [torch] and [onTorch] drive its button.
  const ScanViewfinder({
    required this.preview,
    required this.torch,
    required this.onTorch,
    super.key,
  });

  /// Height of the view.
  static const double height = 300;

  /// The frame the code is aimed at.
  static const Size frame = Size(250, 150);

  /// Side of a corner mark.
  static const double markSize = 36;

  /// Stroke of a corner mark.
  static const double markStroke = 4;

  /// The camera preview.
  final Widget preview;

  /// The torch state; the button is shown unless it is `unavailable`.
  final ValueListenable<ScannerTorch> torch;

  /// Switches the torch.
  final VoidCallback onTorch;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return SizedBox(
      key: const Key('scan-viewfinder'),
      height: height,
      child: ClipRRect(
        borderRadius: PillPalRadius.card,
        child: ColoredBox(
          color: palette.scrim,
          child: Stack(
            fit: StackFit.expand,
            children: [
              preview,
              Center(child: _Frame(color: palette.onHero)),
              Positioned.directional(
                textDirection: Directionality.of(context),
                end: PillPalSpacing.md,
                bottom: PillPalSpacing.md,
                child: ValueListenableBuilder<ScannerTorch>(
                  valueListenable: torch,
                  builder: (context, state, child) =>
                      state == ScannerTorch.unavailable
                          ? const SizedBox.shrink()
                          : _TorchButton(
                              on: state == ScannerTorch.on,
                              onPressed: onTorch,
                            ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The four corner marks around the aiming area.
class _Frame extends StatelessWidget {
  const _Frame({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox.fromSize(
      size: ScanViewfinder.frame,
      child: Stack(
        children: [
          _Corner(key: const Key('scan-corner-tl'), color: color),
          _Corner(key: const Key('scan-corner-tr'), color: color, right: true),
          _Corner(key: const Key('scan-corner-bl'), color: color, bottom: true),
          _Corner(
            key: const Key('scan-corner-br'),
            color: color,
            right: true,
            bottom: true,
          ),
        ],
      ),
    );
  }
}

class _Corner extends StatelessWidget {
  const _Corner({
    required this.color,
    this.right = false,
    this.bottom = false,
    super.key,
  });

  final Color color;
  final bool right;
  final bool bottom;

  @override
  Widget build(BuildContext context) {
    final side = BorderSide(color: color, width: ScanViewfinder.markStroke);
    const round = Radius.circular(PillPalRadius.md);
    return Positioned.directional(
      textDirection: Directionality.of(context),
      start: right ? null : 0,
      end: right ? 0 : null,
      top: bottom ? null : 0,
      bottom: bottom ? 0 : null,
      width: ScanViewfinder.markSize,
      height: ScanViewfinder.markSize,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: BorderDirectional(
            top: bottom ? BorderSide.none : side,
            bottom: bottom ? side : BorderSide.none,
            start: right ? BorderSide.none : side,
            end: right ? side : BorderSide.none,
          ),
          borderRadius: BorderRadiusDirectional.only(
            topStart: !bottom && !right ? round : Radius.zero,
            topEnd: !bottom && right ? round : Radius.zero,
            bottomStart: bottom && !right ? round : Radius.zero,
            bottomEnd: bottom && right ? round : Radius.zero,
          ),
        ),
      ),
    );
  }
}

class _TorchButton extends StatelessWidget {
  const _TorchButton({required this.on, required this.onPressed});

  final bool on;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final side = math.max(PillPalSizes.avatarMd, context.metrics.touchTarget);
    return IconButton.filled(
      key: const Key('scan-torch'),
      tooltip: AppLocalizations.of(context).scanTorch,
      isSelected: on,
      icon: const Icon(Icons.flashlight_off_outlined),
      selectedIcon: const Icon(Icons.flashlight_on),
      onPressed: onPressed,
      constraints: BoxConstraints.tightFor(width: side, height: side),
      style: IconButton.styleFrom(
        backgroundColor: palette.scrim,
        foregroundColor: palette.onHero,
        shape: PillPalRadius.pill,
      ),
    );
  }
}
