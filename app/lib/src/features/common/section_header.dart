import 'package:flutter/material.dart';

import '../../theme/spacing.dart';
import 'gap.dart';

/// The heading of a section of a screen (Family, Settings, ...): title large,
/// `xxl` above it (none when [first]) and `sm` below. [trailing] sits at the
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
        top: first ? 0 : PillPalSpacing.xxl,
        bottom: PillPalSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                key: titleKey,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ),
          if (end != null) end,
        ],
      ),
    );
  }
}

/// The small label above a group of controls (a choice group, a field):
/// title small and `sm` below it.
class GroupLabel extends StatelessWidget {
  /// Creates the label.
  const GroupLabel(this.text, {super.key});

  /// The label.
  final String text;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(text, style: Theme.of(context).textTheme.titleSmall),
        ),
        const Gap.v(PillPalSpacing.sm),
      ],
    );
  }
}
