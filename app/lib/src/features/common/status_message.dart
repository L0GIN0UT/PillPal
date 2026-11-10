import 'package:flutter/material.dart';

import '../../theme/spacing.dart';
import 'gap.dart';

/// An empty, offline or failed state: an icon and a sentence, with an
/// optional [action] below. The one look for such states, so they read the
/// same in every sheet and screen.
class StatusMessage extends StatelessWidget {
  /// Creates the message.
  const StatusMessage({
    required this.icon,
    required this.text,
    this.action,
    super.key,
  });

  /// Leading icon (never the only carrier of the meaning).
  final IconData icon;

  /// The sentence.
  final String text;

  /// A button under the text, such as "Try again".
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    final iconSize = MediaQuery.textScalerOf(context).scale(
      style?.fontSize ?? kDefaultFontSize,
    );
    final below = action;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: PillPalSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: iconSize),
              const Gap.h(PillPalSpacing.sm),
              Expanded(child: Text(text, style: style)),
            ],
          ),
          if (below != null) ...[const Gap.v(PillPalSpacing.sm), below],
        ],
      ),
    );
  }
}
