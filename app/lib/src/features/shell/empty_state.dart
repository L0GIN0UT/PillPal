import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';

/// Centered icon + message used by screens without content yet.
class EmptyState extends StatelessWidget {
  /// Creates an empty state.
  const EmptyState({
    required this.icon,
    required this.message,
    this.action,
    super.key,
  });

  /// Illustration icon.
  final IconData icon;

  /// Explanation text.
  final String message;

  /// Optional call to action below the message.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(PillPalSpacing.xxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: PillPalSizes.iconEmpty, color: palette.action),
            const Gap.v(PillPalSpacing.lg),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            if (action != null) ...[
              const Gap.v(PillPalSpacing.xxl),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
