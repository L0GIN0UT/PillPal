import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/sizes.dart';
import '../../theme/spacing.dart';
import '../common/banner_tone.dart';
import '../common/gap.dart';
import '../common/pillpal_banner.dart';
import 'schedule_draft.dart';
import 'schedule_text.dart';

/// The bar under the schedule form (B2-Schedule): the problems found on
/// save, and «Сохранить», which stays on screen while the form scrolls.
/// [onSave] null disables the button (a finished schedule, a save in
/// progress).
class ScheduleSaveBar extends StatelessWidget {
  /// Creates the bar.
  const ScheduleSaveBar({
    required this.errors,
    required this.onSave,
    super.key,
  });

  /// What is wrong with the draft; empty when nothing.
  final List<ScheduleDraftError> errors;

  /// Save tapped, or null while saving is not possible.
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.background,
        border: Border(
          top: BorderSide(
            color: palette.border,
            width: PillPalSizes.hairline,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: PillPalSpacing.xl,
            vertical: PillPalSpacing.md,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (errors.isNotEmpty) _errorList(context, l10n),
              FilledButton(
                key: const Key('schedule-save'),
                onPressed: onSave,
                style: FilledButton.styleFrom(
                  minimumSize: Size.fromHeight(
                    math.max(
                      PillPalSizes.stackedButtonMin,
                      context.metrics.touchTarget,
                    ),
                  ),
                ),
                child: Text(l10n.save),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The errors in their own scroll, at most a part of the screen high, so
  /// a few of them at a large text size never push the button off screen.
  Widget _errorList(BuildContext context, AppLocalizations l10n) {
    final maxHeight =
        MediaQuery.sizeOf(context).height * PillPalSizes.stickyBarMaxFraction;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final error in errors) ...[
              PillPalBanner(
                tone: BannerTone.danger,
                body: scheduleErrorText(l10n, error),
                liveRegion: true,
              ),
              const Gap.v(PillPalSpacing.sm),
            ],
          ],
        ),
      ),
    );
  }
}
