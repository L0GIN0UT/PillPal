import 'package:flutter/material.dart';

import '../../theme/spacing.dart';
import 'gap.dart';

/// A card with an info icon and an explanation; [trailing] (a dismiss
/// button, for example) sits at the end.
class InfoNote extends StatelessWidget {
  /// Creates the note.
  const InfoNote({required this.text, this.textKey, this.trailing, super.key});

  /// The explanation.
  final String text;

  /// Key of the text, for tests.
  final Key? textKey;

  /// A widget at the end of the row, such as a dismiss button.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final end = trailing;
    return Card(
      child: Padding(
        padding: end == null
            ? PillPalSpacing.card
            : const EdgeInsets.only(
                left: PillPalSpacing.lg,
                top: PillPalSpacing.xs,
                bottom: PillPalSpacing.xs,
              ),
        child: Row(
          crossAxisAlignment: end == null
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          children: [
            const Icon(Icons.info_outline),
            const Gap.h(PillPalSpacing.md),
            Expanded(child: Text(text, key: textKey)),
            if (end != null) end,
          ],
        ),
      ),
    );
  }
}
