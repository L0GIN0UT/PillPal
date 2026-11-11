import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/spacing.dart';
import 'gap.dart';

/// A label with a control under it (a segmented control, a choice group) in
/// a card: the label in the row-title style, so it reads like the title of a
/// `PillPalListRow` or a switch row beside it. [padding] is the padding of a
/// row of the card; pass `EdgeInsets.zero` where the block already sits in a
/// padded one.
class CardControlBlock extends StatelessWidget {
  /// Creates the block.
  const CardControlBlock({
    required this.label,
    required this.child,
    this.padding = PillPalSpacing.cardRow,
    super.key,
  });

  /// What the control sets.
  final String label;

  /// The control.
  final Widget child;

  /// Space around the block.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: Theme.of(context).textTheme.rowTitle),
          const Gap.v(PillPalSpacing.sm),
          child,
        ],
      ),
    );
  }
}
