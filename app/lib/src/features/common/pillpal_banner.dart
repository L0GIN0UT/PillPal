import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/radius.dart';
import '../../theme/spacing.dart';
import 'banner_tone.dart';
import 'gap.dart';

/// The one banner / notice card: an optional [icon], a [title], a [body] and
/// [actions] below them. The [tone] sets colours; the meaning never rests on
/// colour alone (the danger tone always shows an icon). [liveRegion] makes
/// screen readers announce it when it appears (errors).
///
/// Give [key] to the banner itself; [bodyKey] marks the body text.
class PillPalBanner extends StatelessWidget {
  /// Creates the banner; at least one of [title] and [body] is needed.
  const PillPalBanner({
    this.icon,
    this.title,
    this.body,
    this.tone = BannerTone.soft,
    this.actions = const [],
    this.actionsAlignment = WrapAlignment.start,
    this.bodyKey,
    this.liveRegion = false,
    super.key,
  }) : assert(title != null || body != null, 'a banner needs a title or body');

  /// Leading icon; the danger tone falls back to an error icon.
  final IconData? icon;

  /// Heading.
  final String? title;

  /// Explanation.
  final String? body;

  /// Colours of the card.
  final BannerTone tone;

  /// Buttons under the text.
  final List<Widget> actions;

  /// Where the [actions] sit in their row.
  final WrapAlignment actionsAlignment;

  /// Key of the body text, for tests.
  final Key? bodyKey;

  /// Whether screen readers announce the banner when it appears.
  final bool liveRegion;

  @override
  Widget build(BuildContext context) {
    final style = _BannerStyle.of(tone, context.palette);
    final textTheme = Theme.of(context).textTheme;
    final iconData =
        icon ?? (tone == BannerTone.danger ? Icons.error_outline : null);
    final heading = title;
    final text = body;
    final iconWidget = iconData == null
        ? null
        : Icon(
            iconData,
            color: style.icon,
            // Grows with the text, like the words beside it.
            size:
                MediaQuery.textScalerOf(context).scale(PillPalSizes.iconInline),
          );
    final bodyText = text == null
        ? null
        : Text(
            text,
            key: bodyKey,
            style: textTheme.bodyMedium?.copyWith(color: style.text),
          );
    return Semantics(
      liveRegion: liveRegion,
      container: liveRegion,
      child: Card(
        color: style.background,
        shape: RoundedRectangleBorder(
          borderRadius: PillPalRadius.card,
          side: style.border,
        ),
        child: Padding(
          padding: PillPalSpacing.card,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (heading != null)
                _row(
                  iconWidget,
                  Text(
                    heading,
                    style: textTheme.titleMedium?.copyWith(color: style.text),
                  ),
                ),
              if (heading != null && bodyText != null)
                const Gap.v(PillPalSpacing.sm),
              if (bodyText != null)
                heading == null ? _row(iconWidget, bodyText) : bodyText,
              if (actions.isNotEmpty) ...[
                const Gap.v(PillPalSpacing.md),
                SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    spacing: PillPalSpacing.sm,
                    runSpacing: PillPalSpacing.sm,
                    alignment: actionsAlignment,
                    children: actions,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(Widget? leading, Widget text) {
    if (leading == null) {
      return text;
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        leading,
        const Gap.h(PillPalSpacing.md),
        Expanded(child: text),
      ],
    );
  }
}

/// Colours of one [BannerTone].
class _BannerStyle {
  const _BannerStyle({
    required this.background,
    required this.text,
    required this.icon,
    required this.border,
  });

  factory _BannerStyle.of(BannerTone tone, PillPalPalette palette) {
    switch (tone) {
      case BannerTone.soft:
        return _BannerStyle(
          background: palette.actionSoft,
          text: palette.onActionSoft,
          icon: palette.onActionSoft,
          border: BorderSide.none,
        );
      case BannerTone.info:
        return _BannerStyle(
          background: palette.surface,
          text: palette.ink,
          icon: palette.missed,
          border: BorderSide(color: palette.missed, width: _outline),
        );
      case BannerTone.danger:
        return _BannerStyle(
          background: palette.surface,
          text: palette.ink,
          icon: palette.danger,
          border: BorderSide(color: palette.danger, width: _outline),
        );
    }
  }

  /// Outline width of the info and danger tones (as the field borders).
  static const double _outline = 2;

  final Color background;
  final Color text;
  final Color icon;
  final BorderSide border;
}
