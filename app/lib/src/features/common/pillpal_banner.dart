import 'dart:math' as math;

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
/// The text must name the problem: the icon is decorative and hidden from
/// screen readers. The banner has no outer spacing; the caller adds a `Gap`
/// or padding around it.
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

  /// Leading icon; the danger tone falls back to an error icon, the info tone
  /// to an info icon.
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
    final outline = style.border;
    final textTheme = Theme.of(context).textTheme;
    final iconData = icon ??
        switch (tone) {
          BannerTone.danger => Icons.error_outline,
          BannerTone.info => Icons.info_outline,
          BannerTone.soft => null,
        };
    final heading = title;
    final text = body;
    final iconWidget = iconData == null
        ? null
        // Decorative: the title or body names the problem in words.
        : ExcludeSemantics(
            child: Icon(
              iconData,
              color: style.icon,
              // Grows with the text, but not past the senior icon size.
              size: math.min(
                MediaQuery.textScalerOf(context).scale(PillPalSizes.iconInline),
                PillPalSizes.iconSenior,
              ),
            ),
          );
    final bodyText = text == null
        ? null
        : Text(
            text,
            key: bodyKey,
            style: textTheme.bodyLarge?.copyWith(color: style.text),
          );
    return Semantics(
      liveRegion: liveRegion,
      container: liveRegion,
      child: Card(
        color: style.background,
        // The soft tone keeps the card border of the theme.
        shape: outline == null
            ? null
            : RoundedRectangleBorder(
                borderRadius: PillPalRadius.card,
                side: outline,
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
          border: null,
        );
      case BannerTone.info:
        return _BannerStyle(
          background: palette.raised,
          text: palette.ink,
          icon: palette.ink,
          border: null,
        );
      case BannerTone.danger:
        return _BannerStyle(
          background: palette.surface,
          text: palette.ink,
          icon: palette.danger,
          border:
              BorderSide(color: palette.danger, width: PillPalSizes.outline),
        );
    }
  }

  final Color background;
  final Color text;
  final Color icon;
  final BorderSide? border;
}
