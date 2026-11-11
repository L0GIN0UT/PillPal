import 'package:flutter/material.dart';

import 'motion.dart';

/// Screen transitions of the app (B2-README "Motion"): a pushed screen slides
/// in from the right while its opacity goes 0.6 to 1 (`base`,
/// `emphasizedDecelerate`); going back is the same movement reversed with the
/// `standard` curve. With reduced motion the screen only fades (`fast`).
///
/// One builder for every platform: the app looks the same on all of them, and
/// the route length is `base` both ways.
class PillPalPageTransitionsBuilder extends PageTransitionsBuilder {
  /// Creates the builder.
  const PillPalPageTransitionsBuilder();

  /// Opacity at the start of a push and at the end of a pop.
  static const double edgeOpacity = 0.6;

  @override
  Duration get transitionDuration => PillPalMotion.base;

  @override
  Duration get reverseTransitionDuration => PillPalMotion.base;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return PillPalPageTransition(animation: animation, child: child);
  }
}

/// The slide-and-fade of one pushed screen, driven by its route [animation].
class PillPalPageTransition extends StatefulWidget {
  /// Creates the transition.
  const PillPalPageTransition({
    required this.animation,
    required this.child,
    super.key,
  });

  /// The route animation: 0 hidden, 1 shown.
  final Animation<double> animation;

  /// The screen.
  final Widget child;

  @override
  State<PillPalPageTransition> createState() => _PillPalPageTransitionState();
}

class _PillPalPageTransitionState extends State<PillPalPageTransition> {
  late CurvedAnimation _curved;
  bool _reduced = false;

  @override
  void initState() {
    super.initState();
    _curved = _curve();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = PillPalMotion.reduced(context);
    if (reduced != _reduced) {
      _reduced = reduced;
      _curved.dispose();
      _curved = _curve();
    }
  }

  @override
  void didUpdateWidget(PillPalPageTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _curved.dispose();
      _curved = _curve();
    }
  }

  /// A curved animation can only be built from the parent and the curves; the
  /// reverse curve is given flipped, because Flutter plays it backwards.
  CurvedAnimation _curve() {
    if (_reduced) {
      // The fade finishes in `fast` of the route's `base`.
      final fade = Interval(
        0,
        PillPalMotion.fast.inMilliseconds / PillPalMotion.base.inMilliseconds,
      );
      return CurvedAnimation(
        parent: widget.animation,
        curve: fade,
        reverseCurve: fade,
      );
    }
    return CurvedAnimation(
      parent: widget.animation,
      curve: PillPalMotion.emphasizedDecelerate,
      reverseCurve: PillPalMotion.standard.flipped,
    );
  }

  @override
  void dispose() {
    _curved.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fade = FadeTransition(
      opacity: _reduced
          ? _curved
          : Tween<double>(
              begin: PillPalPageTransitionsBuilder.edgeOpacity,
              end: 1,
            ).animate(_curved),
      child: widget.child,
    );
    if (_reduced) {
      return fade;
    }
    return SlideTransition(
      position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
          .animate(_curved),
      child: fade,
    );
  }
}

/// A fade only (the consent gate, the loading screen): the screen replaces
/// the one before it, it does not arrive from anywhere.
class PillPalFadePageTransition extends StatelessWidget {
  /// Creates the transition.
  const PillPalFadePageTransition({
    required this.animation,
    required this.child,
    super.key,
  });

  /// The route animation.
  final Animation<double> animation;

  /// The screen.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: CurveTween(curve: PillPalMotion.standard).animate(animation),
      child: child,
    );
  }
}
