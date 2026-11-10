import 'package:flutter/material.dart';

import '../../theme/spacing.dart';

/// The heading of a section of a screen (Family, Settings, ...): title medium
/// (Manrope 700, 18), `sectionTop` above it (none when [first]) and
/// `sectionBottom` below. [trailing] sits at the
/// end of the row, such as an "Add" button.
class SectionHeader extends StatelessWidget {
  /// Creates the heading.
  const SectionHeader(
    this.title, {
    this.trailing,
    this.first = false,
    this.titleKey,
    super.key,
  });

  /// Section title.
  final String title;

  /// A widget at the end of the row.
  final Widget? trailing;

  /// Whether it is the first element of the screen (no gap above).
  final bool first;

  /// Key of the title text, for tests.
  final Key? titleKey;

  @override
  Widget build(BuildContext context) {
    final end = trailing;
    return Padding(
      padding: EdgeInsets.only(
        top: first ? 0 : PillPalSpacing.sectionTop,
        bottom: PillPalSpacing.sectionBottom,
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                key: titleKey,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ),
          if (end != null) end,
        ],
      ),
    );
  }
}
