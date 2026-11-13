import 'package:material_ui/material_ui.dart';

/// A row with a narrow layout (docs/design.md, narrow screens 7): it can say
/// how wide it must be for its full layout (tile, chevron, trailing control
/// beside the text) without breaking a word inside.
abstract interface class NarrowAware {
  /// The narrowest width for the full layout, or null for a row that has no
  /// narrow layout (a hero card).
  double? fullLayoutWidth(BuildContext context);
}

/// Whether the rows of one list or card take their narrow layout. Every row
/// of a group looks the same: narrow when any of them would break a word in
/// its full layout. Rows outside a [CompactGroup] decide for themselves.
class CompactRows extends InheritedWidget {
  /// Provides [narrow] to the rows of [child].
  const CompactRows({required this.narrow, required super.child, super.key});

  /// Whether the rows take their narrow layout.
  final bool narrow;

  /// Whether the group around [context] is narrow; false without a group.
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CompactRows>()?.narrow ??
      false;

  @override
  bool updateShouldNotify(CompactRows oldWidget) => oldWidget.narrow != narrow;
}

/// Decides [CompactRows] for [rows], laid out by [child] at the width this
/// group gets: the [NarrowAware] rows among [rows] are asked; others (a
/// divider, a section header, a wrapper) count as fitting and still decide
/// for themselves.
///
/// It measures in a `LayoutBuilder`, so it cannot sit inside an
/// `IntrinsicWidth` or `IntrinsicHeight` (no row of the app does).
class CompactGroup extends StatelessWidget {
  /// Creates the group.
  const CompactGroup({required this.rows, required this.child, super.key});

  /// The rows to ask; they are inside [child].
  final List<Widget> rows;

  /// The layout of the rows (a column, a card).
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final narrow = width.isFinite &&
            rows.any((row) {
              final need =
                  row is NarrowAware ? row.fullLayoutWidth(context) : null;
              return need != null && need > width;
            });
        return CompactRows(narrow: narrow, child: child);
      },
    );
  }
}
