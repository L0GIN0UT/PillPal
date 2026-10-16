import 'package:flutter/material.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../common/formatters.dart';
import '../common/info_note.dart';
import 'schedule_widgets.dart';

/// Course dates and time zone of the schedule editor, with a warning when
/// a new course starts in the past (its past days count as missed).
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Column(
              children: [
                InfoRow(
                  key: const Key('course-start'),
                  label: l10n.courseStart,
                  value: formatShortDate(start, locale),
                  onTap: onPickStart,
                ),
                const Divider(height: 1),
                InfoRow(
                  key: const Key('course-end'),
                  label: l10n.courseEnd,
                  value: last == null
                      ? l10n.courseNoEnd
                      : formatShortDate(last, locale),
                  onTap: onPickEnd,
                  trailing: last == null
                      ? null
                      : IconButton(
                          key: const Key('course-end-clear'),
                          tooltip: l10n.courseClearEnd,
                          icon: const Icon(Icons.close),
                          onPressed: onClearEnd,
                        ),
                ),
                const Divider(height: 1),
                InfoRow(label: l10n.timeZone, value: zone ?? l10n.localTime),
              ],
            ),
          ),
        ),
        if (startsInPast) ...[
          const SizedBox(height: 12),
          InfoNote(
            key: const Key('schedule-past-start'),
            text: l10n.schedulePastStartNote,
          ),
        ],
      ],
    );
  }
}
