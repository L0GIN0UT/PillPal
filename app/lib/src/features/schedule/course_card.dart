import 'package:flutter/material.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/radius.dart';
import '../../theme/sizes.dart';
import '../../theme/spacing.dart';
import '../common/banner_tone.dart';
import '../common/formatters.dart';
import '../common/gap.dart';
import '../common/pillpal_banner.dart';

/// Course dates of the schedule editor as two date fields (B2-Schedule), the
/// time zone line, and a warning when a new course starts in the past (its
/// past days count as missed).
class CourseCard extends StatelessWidget {
  /// Creates the card.
  const CourseCard({
    required this.start,
    required this.end,
    required this.zone,
    required this.startsInPast,
    required this.onPickStart,
    required this.onPickEnd,
    required this.onClearEnd,
    super.key,
  });

  /// First day.
  final LocalDate start;

  /// Last day, or null for no end.
  final LocalDate? end;

  /// Fixed zone name, or null for local time.
  final String? zone;

  /// Whether to warn that the past days will be counted as missed.
  final bool startsInPast;

  /// Start date tapped.
  final VoidCallback onPickStart;

  /// End date tapped.
  final VoidCallback onPickEnd;

  /// End date cleared.
  final VoidCallback onClearEnd;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toLanguageTag();
    final last = end;
    final startField = _DateField(
      fieldKey: const Key('course-start'),
      label: l10n.courseStart,
      value: formatShortDate(start, locale),
      onTap: onPickStart,
    );
    final endField = _DateField(
      fieldKey: const Key('course-end'),
      label: l10n.courseEnd,
      value: last == null ? l10n.courseNoEnd : formatShortDate(last, locale),
      onTap: onPickEnd,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            // Two fields side by side only where there is room (B2-README
            // section 9: pairs stack on phones, at large text, in senior mode).
            final stacked =
                constraints.maxWidth < PillPalSizes.dateFieldPairMinWidth ||
                    context.stacksPair ||
                    context.metrics.isSenior;
            if (stacked) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  startField,
                  const Gap.v(PillPalSpacing.md),
                  endField,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: startField),
                const Gap.h(PillPalSpacing.md),
                Expanded(child: endField),
              ],
            );
          },
        ),
        if (last != null)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const Key('course-end-clear'),
              onPressed: onClearEnd,
              icon: const Icon(Icons.close),
              label: Text(l10n.courseClearEnd),
            ),
          ),
        const Gap.v(PillPalSpacing.sm),
        Text(
          '${l10n.timeZone}: ${zone ?? l10n.localTime}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (startsInPast) ...[
          const Gap.v(PillPalSpacing.md),
          PillPalBanner(
            key: const Key('schedule-past-start'),
            tone: BannerTone.info,
            body: l10n.schedulePastStartNote,
          ),
        ],
      ],
    );
  }
}

/// A label above a field that shows a date and opens a picker when tapped.
class _DateField extends StatelessWidget {
  const _DateField({
    required this.fieldKey,
    required this.label,
    required this.value,
    required this.onTap,
  });

  final Key fieldKey;
  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: textTheme.titleSmall),
        const Gap.v(PillPalSpacing.xs),
        Semantics(
          button: true,
          label: '$label, $value',
          onTap: onTap,
          excludeSemantics: true,
          child: InkWell(
            key: fieldKey,
            onTap: onTap,
            borderRadius: PillPalRadius.control,
            // The fill is an Ink under the decorator: a filled decorator would
            // paint over the ripple of the InkWell.
            child: Ink(
              decoration: ShapeDecoration(
                color: context.palette.surface,
                shape: const RoundedRectangleBorder(
                  borderRadius: PillPalRadius.control,
                ),
              ),
              child: InputDecorator(
                decoration: InputDecoration(
                  filled: false,
                  constraints:
                      BoxConstraints(minHeight: context.metrics.touchTarget),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.calendar_today_outlined,
                      size: PillPalSizes.iconInline,
                      color: context.palette.inkMuted,
                    ),
                    const Gap.h(PillPalSpacing.sm),
                    Expanded(child: Text(value, style: textTheme.bodyLarge)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
