import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../theme/motion.dart';

/// The container of the four tab Navigators: a page turn (B2-README "Motion",
/// «Tab switch»).
///
/// Switching to another tab moves the whole old page and the whole new page
/// one full width, in sync and in the direction of the tab order (a tab to
/// the right enters from the right, the old page leaves to the left): no fade,
/// no scale, no parallax; `slow`, `emphasizedDecelerate`. With reduced motion
/// the pages cross-fade (`fast`) and do not move.
///
/// Every page stays in the tree in the same place, like an `IndexedStack`:
/// a tab keeps its navigator, state and scroll position while it is hidden.
/// Only the shell around the pager (status area, navigation bar) is fixed.
///
/// Used as the `navigatorContainerBuilder` of the `StatefulShellRoute`: the
/// [children] are its branch navigators in tab order.
class TabPager extends StatefulWidget {
  /// Creates the pager showing [children] at [currentIndex].
  const TabPager({
    required this.currentIndex,
    required this.children,
    super.key,
  });

  /// The selected tab.
  final int currentIndex;

  /// The page of each tab, in tab order.
  final List<Widget> children;

  @override
  State<TabPager> createState() => _TabPagerState();
}

class _TabPagerState extends State<TabPager>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curved;

  /// The tab being left while a turn runs; null at rest.
  int? _leaving;

  /// Whether the running turn fades (reduced motion) instead of moving.
  bool _fades = false;

  @override
  void initState() {
    super.initState();
    // Value 1 is "at rest": the first build shows the tab without a turn.
    // `preserve`: the system's "remove animations" would shrink the controller
    // to a few milliseconds, and reduced motion wants a real fade (`fast`).
    _controller = AnimationController(
      vsync: this,
      value: 1,
      animationBehavior: AnimationBehavior.preserve,
    )..addStatusListener(_onStatus);
    _curved = CurvedAnimation(
      parent: _controller,
      curve: PillPalMotion.emphasizedDecelerate,
    );
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _leaving != null) {
      setState(() => _leaving = null);
    }
  }

  @override
  void didUpdateWidget(TabPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex == widget.currentIndex) {
      return;
    }
    _fades = PillPalMotion.reduced(context);
    _leaving = oldWidget.currentIndex;
    _controller.duration = _fades ? PillPalMotion.fast : PillPalMotion.slow;
    unawaited(_controller.forward(from: 0));
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: IgnorePointer(
        // A page that is still sliding is not a target for a tap.
        ignoring: _leaving != null,
        child: AnimatedBuilder(
          animation: _curved,
          builder: (context, _) => Stack(
            fit: StackFit.expand,
            children: [
              for (var index = 0; index < widget.children.length; index++)
                _page(index),
            ],
          ),
        ),
      ),
    );
  }

  Widget _page(int index) {
    final current = index == widget.currentIndex;
    final leaving = index == _leaving;
    final progress = _curved.value;
    // The turn: both pages cover one width in the same time.
    final direction = widget.currentIndex > (_leaving ?? 0) ? 1.0 : -1.0;
    var shift = 0.0;
    var opacity = 1.0;
    if (_leaving != null) {
      if (_fades) {
        opacity = current ? progress : (leaving ? 1 - progress : 1);
      } else if (current) {
        shift = direction * (1 - progress);
      } else if (leaving) {
        shift = -direction * progress;
      }
    }
    final shown = current || leaving;
    // The same widgets in the same order at every state keep each tab alive.
    return Offstage(
      offstage: !shown,
      child: TickerMode(
        enabled: shown,
        child: FractionalTranslation(
          translation: Offset(shift, 0),
          child: Opacity(opacity: opacity, child: widget.children[index]),
        ),
      ),
    );
  }
}
