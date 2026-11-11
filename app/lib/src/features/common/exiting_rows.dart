import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../theme/motion.dart';

/// Lays out [rows] through [builder] and lets a row that disappears from
/// [rows] fade out and collapse to zero height (`base`, `standard`;
/// docs/design/b2/README.md, «List row removed») instead of vanishing at once.
/// With reduced motion a removed row is gone at once.
///
/// Every row needs a key that stays the same for the same item. The builder
/// puts the widgets it gets, in order, into a column or a card; a row that is
/// leaving is the last widget it was given, ignoring taps.
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
  _Entry(this.row, {this.exiting = false});

  Widget row;
  bool exiting;

  Key get key => ValueKey<Key?>(row.key);
}

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
      for (var i = 0; i < _entries.length; i++) {
        final old = _entries[i];
        if (!current.containsKey(old.row.key)) {
          old.exiting = true;
          next.insert(i < next.length ? i : next.length, old);
        }
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
          onGone: () => _gone(entry),
          child: entry.row,
        ),
    ]);
  }
}

class _Collapse extends StatefulWidget {
  const _Collapse({
    required this.exiting,
    required this.onGone,
    required this.child,
    super.key,
  });

  final bool exiting;
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
    _curved = CurvedAnimation(
      parent: _controller,
      curve: PillPalMotion.standard,
    );
    if (widget.exiting) {
      unawaited(_controller.reverse());
    }
  }

  @override
  void didUpdateWidget(_Collapse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.exiting && !oldWidget.exiting) {
      unawaited(_controller.reverse());
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
      axisAlignment: -1,
      child: FadeTransition(
        opacity: _curved,
        child: IgnorePointer(ignoring: widget.exiting, child: widget.child),
      ),
    );
  }
}
