import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import 'gap.dart';

/// How a button of a [PillPalDialog] looks.
enum DialogChoiceKind {
  /// Solid `danger`: deletes, revokes or discards. Used only here.
  destructive,

  /// Solid `action`: the recommended safe choice.
  primary,

  /// Outlined: cancel and the other safe choices.
  secondary,
}

/// One button of a [PillPalDialog]. Plain data: [key] goes to the button
/// itself, so tests find and tap it.
@immutable
class DialogChoice {
  /// Creates a choice.
  const DialogChoice({
    required this.label,
    required this.onPressed,
    this.kind = DialogChoiceKind.secondary,
    this.key,
  });

  /// Text of the button.
  final String label;

  /// Called on tap (the caller closes the dialog).
  final VoidCallback onPressed;

  /// Look of the button.
  final DialogChoiceKind kind;

  /// Key of the button.
  final Key? key;
}

/// The dialog of the app (board B2-DangerDialog): radius 28, padding 24, an
/// optional `dangerSoft` icon disc for [destructive] dialogs, a title, a
/// [body], a [consequences] list and the [choices] stacked at full width, in
/// the given order (the destructive one first).
///
/// It scrolls as a whole, so large text never pushes the buttons off screen.
/// Show it with `showDialog`.
class PillPalDialog extends StatelessWidget {
  /// Creates the dialog.
  const PillPalDialog({
    required this.title,
    required this.body,
    required this.choices,
    this.consequences = const [],
    this.destructive = false,
    super.key,
  });

  /// Heading.
  final String title;

  /// Explanation under the heading.
  final String body;

  /// Buttons, top to bottom.
  final List<DialogChoice> choices;

  /// What happens, one short sentence each (shown as a bulleted list).
  final List<String> consequences;

  /// Whether the dialog warns about something that cannot be taken back: it
  /// shows the danger icon disc.
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: PillPalSpacing.lg,
        vertical: PillPalSpacing.xxl,
      ),
      contentPadding: const EdgeInsets.all(PillPalSpacing.xxl),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (destructive) ...[
              const Align(
                alignment: AlignmentDirectional.centerStart,
                child: _DangerDisc(),
              ),
              const Gap.v(PillPalSpacing.lg),
            ],
            Semantics(
              header: true,
              child: Text(title, style: textTheme.headlineSmall),
            ),
            const Gap.v(PillPalSpacing.sm),
            Text(body, style: textTheme.bodyLarge),
            if (consequences.isNotEmpty) ...[
              const Gap.v(PillPalSpacing.md),
              for (final item in consequences) _Consequence(item),
            ],
            const Gap.v(PillPalSpacing.xl),
            for (var i = 0; i < choices.length; i++) ...[
              if (i > 0) const Gap.v(PillPalSpacing.sm),
              _button(context, choices[i]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _button(BuildContext context, DialogChoice choice) {
    final palette = context.palette;
    final label = Text(choice.label, textAlign: TextAlign.center);
    switch (choice.kind) {
      case DialogChoiceKind.destructive:
        return FilledButton(
          key: choice.key,
          onPressed: choice.onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: palette.danger,
            foregroundColor: palette.onDanger,
          ),
          child: label,
        );
      case DialogChoiceKind.primary:
        return FilledButton(
          key: choice.key,
          onPressed: choice.onPressed,
          child: label,
        );
      case DialogChoiceKind.secondary:
        return OutlinedButton(
          key: choice.key,
          onPressed: choice.onPressed,
          child: label,
        );
    }
  }
}

/// The 48 circle of a destructive dialog.
class _DangerDisc extends StatelessWidget {
  const _DangerDisc();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return SizedBox.square(
      key: const Key('dialog-icon'),
      dimension: PillPalSizes.avatarMd,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: palette.dangerSoft,
          shape: BoxShape.circle,
        ),
        // Decorative: the title says what the dialog is about.
        child: ExcludeSemantics(
          child: Icon(Icons.warning_amber_rounded, color: palette.onDangerSoft),
        ),
      ),
    );
  }
}

/// One bullet of the consequences list.
class _Consequence extends StatelessWidget {
  const _Consequence(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: context.palette.inkMuted,
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: PillPalSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(child: Text('•', style: style)),
          const Gap.h(PillPalSpacing.sm),
          Expanded(child: Text(text, style: style)),
        ],
      ),
    );
  }
}
