import 'package:flutter/material.dart';

import '../../theme/spacing.dart';
import 'gap.dart';

/// The small label above a group of controls (a choice group, a field):
/// title small and `sm` below it. A plain label, not a heading: screen
/// readers read it with the controls, not as a landmark.
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
        Text(text, style: Theme.of(context).textTheme.titleSmall),
        const Gap.v(PillPalSpacing.sm),
      ],
    );
  }
}
