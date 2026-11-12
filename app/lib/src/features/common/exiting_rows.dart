import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../theme/motion.dart';

/// Lays out [rows] through [builder] and lets a row that disappears from
/// [rows] fade out and collapse to zero height (`base`, `standard`;
/// docs/design/b2/README.md, «List row removed») instead of vanishing at once.
/// Rows that leave together start one `stagger` after another, top to bottom
/// («Удалить все»). With reduced motion a removed row is gone at once.
///
/// Every row needs a key that stays the same for the same item. The builder
/// puts the widgets it gets, in order, into a column or a card; a row that is
/// leaving is the last widget it was given, ignoring taps. Once the last row
/// has left, the builder gets an empty list and can show the empty state.
class ExitingRows extends StatefulWidget {
  /// Creates the list.
  const ExitingRows({required this.rows, required this.builder, super.key});

  /// The rows that are on the list now, each with a key.
  final List<Widget> rows;

  /// Builds the list around the [rows] to show (current and leaving).
  final Widget Function(BuildContext context, List<Widget> rows) builder;

  @override
  State<ExitingRows> createState() => _ExitingRowsState();
}

class _Entry {
  _Entry(this.row);

  final Widget row;

  /// Whether the row left the list and is on its way out.
  bool exiting = false;

  /// How long the row waits before it starts to leave.
  Duration delay = Duration.zero;

  Key get key => ValueKey<Key?>(row.key);
}

/// Rows after this many leave together with the last staggered one, so a long
/// list does not take seconds to clear.
const int _maxStaggerSteps = 6;

class _ExitingRowsState extends State<ExitingRows> {
  late List<_Entry> _entries = [for (final row in widget.rows) _Entry(row)];

  @override
  void initState() {
    super.initState();
    assert(_allKeyed(), 'every row of ExitingRows needs a key');
  }

  bool _allKeyed() => widget.rows.every((row) => row.key != null);

  @override
  void didUpdateWidget(ExitingRows oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(_allKeyed(), 'every row of ExitingRows needs a key');
    final current = {for (final row in widget.rows) row.key: row};
    final next = [for (final row in widget.rows) _Entry(row)];
    if (!PillPalMotion.reduced(context)) {
      // A row that left stays where it was, between its old neighbours.
      var step = 0;
      for (var i = 0; i < _entries.length; i++) {
        final old = _entries[i];
        if (current.containsKey(old.row.key)) {
          continue;
        }
        if (!old.exiting) {
          old
            ..exiting = true
            ..delay = PillPalMotion.stagger * step;
          if (step < _maxStaggerSteps) {
            step++;
          }
        }
        next.insert(i < next.length ? i : next.length, old);
      }
    }
    _entries = next;
  }

  void _gone(_Entry entry) {
    if (mounted) {
      setState(() => _entries.remove(entry));
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, [
      for (final entry in _entries)
        _Collapse(
          key: entry.key,
          exiting: entry.exiting,
          delay: entry.delay,
          onGone: () => _gone(entry),
          child: entry.row,
        ),
    ]);
  }
}

class _Collapse extends StatefulWidget {
  const _Collapse({
    required this.exiting,
    required this.delay,
    required this.onGone,
    required this.child,
    super.key,
  });

  final bool exiting;
  final Duration delay;
  final VoidCallback onGone;
  final Widget child;

  @override
  State<_Collapse> createState() => _CollapseState();
}

class _CollapseState extends State<_Collapse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final CurvedAnimation _curved;

  @override
  void initState() {
    super.initState();
    // A row present from the start (or added later) is simply there.
    _controller = AnimationController(
      vsync: this,
      value: 1,
      duration: PillPalMotion.base,
    )..addStatusListener((status) {
        if (status == AnimationStatus.dismissed) {
          widget.onGone();
        }
      });
    _curved = CurvedAnimation(parent: _controller, curve: _leaveCurve());
    if (widget.exiting) {
      _leave();
    }
  }

  Duration get _leaveDuration => widget.delay + PillPalMotion.base;

  /// The controller runs from 1 down to 0 over the delay and then `base`:
  /// the row stays whole for the delay and collapses in the rest. The curve
  /// is flipped because the controller plays it backwards.
  Curve _leaveCurve() => Interval(
        0,
        PillPalMotion.base.inMicroseconds / _leaveDuration.inMicroseconds,
        curve: PillPalMotion.standard.flipped,
      );

  void _leave() {
    _controller.reverseDuration = _leaveDuration;
    _curved.curve = _leaveCurve();
    unawaited(_controller.reverse());
  }

  @override
  void didUpdateWidget(_Collapse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.exiting && !oldWidget.exiting) {
      _leave();
    } else if (!widget.exiting && oldWidget.exiting) {
      // The same item came back while it was leaving.
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
    return SizeTransition(
      sizeFactor: _curved,
      // Collapses towards the top: the rows below move up into the gap.
      alignment: AlignmentDirectional.topStart,
      child: FadeTransition(
        opacity: _curved,
        child: IgnorePointer(ignoring: widget.exiting, child: widget.child),
      ),
    );
  }
}
