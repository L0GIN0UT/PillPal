import 'package:flutter/material.dart';

import '../../theme/motion.dart';
import '../../theme/palette.dart';
import '../../theme/sizes.dart';

/// Opens a dialog like `showDialog`, with the motion of the app (B2-README
/// "Motion", «Dialog»): the dialog fades in over a fading scrim and grows from
/// 0.96 (`base` in, `fast` out). With reduced motion it only fades, and on a
/// device the system flag makes that fade near-instant
/// (`PillPalMotion.reduced`). Like `showDialog`, the scrim is the dialog
/// theme's and focus stays inside the dialog. Resolves with the value popped.
Future<T?> showPillPalDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  final barrierColor = DialogTheme.of(context).barrierColor ??
      Theme.of(context).dialogTheme.barrierColor ??
      context.palette.scrim.withValues(alpha: PillPalSizes.scrimOpacity);
  return navigator.push<T>(
    _PillPalDialogRoute<T>(
      context: context,
      builder: builder,
      barrierColor: barrierColor,
      barrierDismissible: barrierDismissible,
      traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
    ),
  );
}

/// The scale a dialog starts from.
const double _startScale = 0.96;

class _PillPalDialogRoute<T> extends DialogRoute<T> {
  _PillPalDialogRoute({
    required super.context,
    required super.builder,
    required super.barrierColor,
    required super.barrierDismissible,
    required super.barrierLabel,
    required super.traversalEdgeBehavior,
    required super.themes,
  });

  @override
  Duration get transitionDuration => PillPalMotion.base;

  @override
  Duration get reverseTransitionDuration => PillPalMotion.fast;

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    // A tween, not a CurvedAnimation: this runs on every build and a curved
    // animation would have to be disposed.
    final curved = CurveTween(curve: PillPalMotion.standard).animate(animation);
    final faded = FadeTransition(opacity: curved, child: child);
    if (PillPalMotion.reduced(context)) {
      return faded;
    }
    return ScaleTransition(
      scale: Tween<double>(begin: _startScale, end: 1).animate(curved),
      child: faded,
    );
  }
}
