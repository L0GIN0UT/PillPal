import 'package:flutter/widgets.dart';

import '../../theme/motion.dart';

/// Swaps one content for another in place (docs/design/b2/README.md, «Sheet
/// content swap»): the old [child] fades out alone (`fast`), then the box
/// takes the height of the new one while the new one fades in (`base`,
/// `standard`): 400 ms in all, a little over `slow`, because the two steps
/// are the rule (docs/design.md, "Motion"). With reduced motion the swap is
/// instant.
///
/// The swap runs when the key of [child] changes; a rebuild with the same key
/// only updates the content.
class ContentSwap extends StatelessWidget {
  /// Shows [child], which needs a key that names its state.
  const ContentSwap({required this.child, super.key});

  /// The content shown now.
  final Widget child;

  static final Duration _total = PillPalMotion.fast + PillPalMotion.base;

  /// The new content waits for the old one to leave, then takes `base`.
  static final Curve _fadeIn = Interval(
    PillPalMotion.fast.inMicroseconds / _total.inMicroseconds,
    1,
    curve: PillPalMotion.standard,
  );

  /// While an old content is leaving it is the only one in the box, so the
  /// box keeps the old height until the new content comes.
  static Widget _oneAtATime(Widget? current, List<Widget> leaving) {
    if (leaving.isNotEmpty) {
      return leaving.last;
    }
    return current ?? const SizedBox.shrink();
  }

  @override
  Widget build(BuildContext context) {
    assert(child.key != null, 'the content of ContentSwap needs a key');
    if (PillPalMotion.reduced(context)) {
      return child;
    }
    return AnimatedSize(
      duration: PillPalMotion.base,
      curve: PillPalMotion.standard,
      alignment: Alignment.topCenter,
      child: AnimatedSwitcher(
        duration: _total,
        reverseDuration: PillPalMotion.fast,
        switchInCurve: _fadeIn,
        // Flutter plays the way out backwards.
        switchOutCurve: PillPalMotion.standard.flipped,
        layoutBuilder: _oneAtATime,
        child: child,
      ),
    );
  }
}
