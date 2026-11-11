import 'package:flutter/material.dart';

import '../../theme/sizes.dart';

/// A checkbox with its label at the start (B2-Consent, report sheet, catalog
/// consent): one look for every tick box of the app.
///
/// The [footer] (a link, a version line) sits under the label and starts where
/// the label does ([PillPalSizes.checkTileLabelIndent]). [emphasized] sets the
/// label in the title style (a box that stands alone in a card); otherwise it
/// is the body text.
///
/// [tileKey] is on the [CheckboxListTile] itself, which tests read.
class PillPalCheckTile extends StatelessWidget {
  /// Creates the tile; [onChanged] null disables it.
  const PillPalCheckTile({
    required this.value,
    required this.onChanged,
    required this.title,
    this.subtitle,
    this.footer,
    this.emphasized = false,
    this.tileKey,
    super.key,
  });

  /// Whether the box is ticked.
  final bool value;

  /// Called with the new value; null makes the tile inert.
  final ValueChanged<bool>? onChanged;

  /// The label.
  final String title;

  /// Explanation under the label.
  final String? subtitle;

  /// Widgets under the explanation, aligned with the label (a link, a note).
  final List<Widget>? footer;

  /// Whether the label is a title.
  final bool emphasized;

  /// Key of the [CheckboxListTile].
  final Key? tileKey;

  @override
  Widget build(BuildContext context) {
    final explanation = subtitle;
    final extra = footer ?? const <Widget>[];
    final change = onChanged;
    final tile = CheckboxListTile(
      key: tileKey,
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: value,
      onChanged: change == null ? null : (ticked) => change(ticked ?? false),
      title: Text(
        title,
        style: emphasized ? Theme.of(context).textTheme.titleMedium : null,
      ),
      subtitle: explanation == null ? null : Text(explanation),
    );
    if (extra.isEmpty) {
      return tile;
    }
    // Outside the tile: a link inside it would sit in the tile's own tap area.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        tile,
        Padding(
          padding: const EdgeInsetsDirectional.only(
            start: PillPalSizes.checkTileLabelIndent,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: extra,
          ),
        ),
      ],
    );
  }
}
