import 'package:flutter/widgets.dart';

/// Empty space of a spacing token (`PillPalSpacing`) between siblings of a
/// column ([Gap.v]) or a row ([Gap.h]).
class Gap extends StatelessWidget {
  /// A vertical gap of [size].
  const Gap.v(this.size, {super.key}) : vertical = true;

  /// A horizontal gap of [size].
  const Gap.h(this.size, {super.key}) : vertical = false;

  /// Length of the gap.
  final double size;

  /// Whether the gap separates rows of a column.
  final bool vertical;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: vertical ? size : null,
      width: vertical ? null : size,
    );
  }
}
