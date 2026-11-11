import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../theme/motion.dart';
import '../../theme/spacing.dart';

/// Brings [child] in when it is first built: it fades in and slides down
/// [PillPalSpacing.lg] (`base`, `emphasizedDecelerate`; docs/design/b2/README.md,
/// «Banner»). With reduced motion it only fades (`fast`). It does not play
/// again when the parent rebuilds, only when the widget is inserted.
///
/// The translation does not change the layout, and the semantics of [child]
/// stay in the tree from the first frame, so a screen reader and a tap find it
/// at once.
class PillPalAppear extends StatefulWidget {
  /// Wraps [child].
  const PillPalAppear({required this.child, super.key});

  /// The widget that appears.
  final Widget child;

  @override
  State<PillPalAppear> createState() => _PillPalAppearState();
}

class _PillPalAppearState extends State<PillPalAppear>
    with SingleTickerProviderStateMixin {
  // `preserve`: the system's "remove animations" would otherwise shrink the
  // controller to a few milliseconds, and reduced motion wants a real fade.
  late final AnimationController _controller = AnimationController(
    vsync: this,
    animationBehavior: AnimationBehavior.preserve,
  );
  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _controller,
    curve: PillPalMotion.emphasizedDecelerate,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_started) {
      _started = true;
      _controller.duration = PillPalMotion.reduced(context)
          ? PillPalMotion.fast
          : PillPalMotion.base;
      unawaited(_controller.forward());
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = PillPalMotion.reduced(context);
    return AnimatedBuilder(
      animation: _curved,
      child: widget.child,
      builder: (context, child) => Opacity(
        opacity: _curved.value,
        alwaysIncludeSemantics: true,
        child: Transform.translate(
          offset: reduced
              ? Offset.zero
              : Offset(0, -PillPalSpacing.lg * (1 - _curved.value)),
          child: child,
        ),
      ),
    );
  }
}
