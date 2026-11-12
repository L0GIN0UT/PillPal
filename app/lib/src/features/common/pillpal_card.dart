import 'package:flutter/material.dart';

import '../../theme/palette.dart';
import '../../theme/app_theme.dart';
import '../../theme/radius.dart';
import '../../theme/shadows.dart';
import '../../theme/spacing.dart';

/// The card of the «Забота» system: `surface`, radius 20, elevation level 1
/// in light themes and none in dark ones, where the surface is lighter than
/// the page instead (B2-README sections 3 and 6). Material elevation tints do
/// not match the design, so the shadow is drawn here and `CardTheme` stays
/// flat.
///
/// The card is a [Material], so an [InkWell] inside it (a list row) splashes
/// on the card. [padding] is 16 unless the content brings its own (rows).
class PillPalCard extends StatelessWidget {
  /// Creates a card around [child].
  const PillPalCard({
    required this.child,
    this.padding = PillPalSpacing.card,
    super.key,
  });

  /// A card of rows (`PillPalListRow`) with a 1 px `border` divider between
  /// them and no padding of its own.
  PillPalCard.rows({required List<Widget> rows, Key? key})
      : this(key: key, padding: EdgeInsets.zero, child: _DividedRows(rows));

  /// A card of rows that bring their own dividers (`ExitingRows` with a
  /// `PillPalRowDivider` separator), no padding of its own.
  PillPalCard.dividedRows({required List<Widget> rows, Key? key})
      : this(
          key: key,
          padding: EdgeInsets.zero,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: rows,
          ),
        );

  /// The content.
  final Widget child;

  /// Space between the edge and the content.
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: PillPalRadius.card,
        boxShadow: PillPalShadows.forBrightness(
          Theme.of(context).brightness,
          PillPalShadows.level1,
        ),
      ),
      child: Material(
        color: context.palette.surface,
        shape: const RoundedRectangleBorder(borderRadius: PillPalRadius.card),
        clipBehavior: Clip.antiAlias,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// [rows] one under another, a hairline `border` line between neighbours.
class _DividedRows extends StatelessWidget {
  const _DividedRows(this.rows);

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const PillPalRowDivider(),
          rows[i],
        ],
      ],
    );
  }
}

/// The 1 px `border` line between the rows of a card.
class PillPalRowDivider extends StatelessWidget {
  /// Creates the line.
  const PillPalRowDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: PillPalSizes.hairline,
      thickness: PillPalSizes.hairline,
      color: context.palette.border,
    );
  }
}
