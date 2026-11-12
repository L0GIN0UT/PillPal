import 'package:material_ui/material_ui.dart';

import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import '../common/stacked_buttons.dart';

/// Centered illustration, message and actions, used by screens without
/// content yet (boards B2-EmptyMedications and B2-EmptyFamily): a soft disc
/// with an icon, an optional [headline], the [message] and a primary
/// ([action]) and an optional [secondaryAction] at full width.
class EmptyState extends StatelessWidget {
  /// Creates an empty state.
  const EmptyState({
    required this.icon,
    required this.message,
    this.headline,
    this.action,
    this.secondaryAction,
    super.key,
  });

  /// Illustration icon, drawn on a soft disc.
  final IconData icon;

  /// Explanation text.
  final String message;

  /// Short heading above the [message].
  final String? headline;

  /// Primary call to action below the message.
  final Widget? action;

  /// Optional second action under [action], such as "Add manually".
  final Widget? secondaryAction;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final textTheme = Theme.of(context).textTheme;
    final title = headline;
    final primary = action;
    final secondary = secondaryAction;
    // Scrolls when the text (senior, large system scale) outgrows a short
    // viewport; centred otherwise.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: constraints.hasBoundedHeight ? constraints.maxHeight : 0,
          ),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(PillPalSpacing.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: SizedBox.square(
                      key: const Key('empty-state-disc'),
                      dimension: PillPalSizes.emptyDisc,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: palette.actionSoft,
                          shape: BoxShape.circle,
                        ),
                        // Decorative: the text says what is empty.
                        child: ExcludeSemantics(
                          child: Icon(
                            icon,
                            size: PillPalSizes.iconEmpty,
                            color: palette.onActionSoft,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Gap.v(PillPalSpacing.xl),
                  if (title != null) ...[
                    Semantics(
                      header: true,
                      child: Text(
                        title,
                        textAlign: TextAlign.center,
                        style: textTheme.headlineSmall,
                      ),
                    ),
                    const Gap.v(PillPalSpacing.sm),
                  ],
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: textTheme.bodyLarge?.copyWith(
                      color: title == null ? null : palette.inkMuted,
                    ),
                  ),
                  if (primary != null || secondary != null) ...[
                    const Gap.v(PillPalSpacing.xxl),
                    StackedButtons(
                      children: [
                        if (primary != null) primary,
                        if (secondary != null) secondary,
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
