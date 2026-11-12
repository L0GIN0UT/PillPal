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
/// Only the page being shown is in the semantics tree and can take focus; the
/// page that is leaving takes no taps, the entering one takes them at once.
///
/// Choosing again mid-turn does not jump: going back to the tab being left
/// plays the turn backwards from where it is; a third tab starts a new turn
/// from the place the page being left has reached, the new page glued to it
/// (the first page of the old turn goes at once).
///
/// The direction is physical, left to right, and not mirrored for a
/// right-to-left locale: the app ships Russian and English only. A right-to-
/// left language would need the turn mirrored with the tab order.
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

  /// The page a running turn moves away; null at rest.
  int? _from;

  /// The page a running turn brings in.
  int _to = 0;

  /// Where [_from] started the turn, in widths (0 unless it was retargeted).
  double _start = 0;

  /// Whether the running turn fades (reduced motion) instead of moving.
  bool _fades = false;

  /// Set while a new turn resets the controller, whose status then passes
  /// through `dismissed` without the turn being over.
  bool _restarting = false;

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
    if (status.isAnimating || _restarting || _from == null) {
      return;
    }
    setState(() => _from = null);
  }

  @override
  void didUpdateWidget(TabPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = widget.currentIndex;
    if (oldWidget.currentIndex == target) {
      return;
    }
    if (_from != null && target == _from) {
      // Back to the page being left: the same turn, backwards.
      unawaited(_controller.reverse());
      return;
    }
    if (_from != null && target == _to) {
      unawaited(_controller.forward());
      return;
    }
    final leaving = oldWidget.currentIndex;
    final start = _from == null ? 0.0 : _shiftOf(leaving);
    _fades = PillPalMotion.reduced(context);
    _controller.duration =
        PillPalMotion.transition(context, PillPalMotion.slow);
    _restarting = true;
    _controller.value = 0;
    _restarting = false;
    _from = leaving;
    _to = target;
    _start = start;
    unawaited(_controller.forward());
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
    );
  }

  /// The direction of the running turn: 1 when [_to] is to the right.
  double get _direction => _to > (_from ?? 0) ? 1.0 : -1.0;

  /// The horizontal place of [index] in widths: [_from] goes from [_start]
  /// to one width away, [_to] stays glued to it and ends at 0.
  double _shiftOf(int index) {
    if (_from == null || _fades) {
      return 0;
    }
    final progress = _curved.value;
    final from = _start * (1 - progress) - _direction * progress;
    if (index == _from) {
      return from;
    }
    return index == _to ? from + _direction : 0;
  }

  double _opacityOf(int index) {
    if (_from == null || !_fades) {
      return 1;
    }
    final progress = _curved.value;
    if (index == _to) {
      return progress;
    }
    return index == _from ? 1 - progress : 1;
  }

  Widget _page(int index) {
    final current = index == widget.currentIndex;
    final shown =
        current || (_from != null && (index == _from || index == _to));
    // The same widgets in the same order at every state keep each tab alive;
    // only their flags change.
    return Offstage(
      offstage: !shown,
      child: TickerMode(
        enabled: shown,
        // Only the selected page is read out and focusable; the page being
        // left is not a target for a tap while it slides away.
        child: ExcludeSemantics(
          excluding: !current,
          child: ExcludeFocus(
            excluding: !current,
            child: IgnorePointer(
              ignoring: !current,
              child: FractionalTranslation(
                translation: Offset(_shiftOf(index), 0),
                child: Opacity(
                  opacity: _opacityOf(index),
                  child: widget.children[index],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
