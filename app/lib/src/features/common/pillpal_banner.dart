import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/radius.dart';
import '../../theme/spacing.dart';
import 'banner_tone.dart';
import 'gap.dart';

/// The one banner / notice card (radius 20, no border): an optional [icon], a
/// [title], a [body] and [actions] below them. The [tone] sets a soft fill and
/// its on-colour; the meaning never rests on colour alone (the danger tone
/// always shows an icon). [liveRegion] makes
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
    this.trailing,
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

  /// A widget at the end of the first row, such as a dismiss button.
  final Widget? trailing;

  /// Key of the body text, for tests.
  final Key? bodyKey;

  /// Whether screen readers announce the banner when it appears.
  final bool liveRegion;

  @override
  Widget build(BuildContext context) {
    final style = _BannerStyle.of(tone, context.palette);
    final textTheme = Theme.of(context).textTheme;
    final heading = title;
    final text = body;
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
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: style.background,
          borderRadius: PillPalRadius.card,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            vertical: PillPalSizes.bannerPaddingVertical,
            horizontal: PillPalSizes.bannerPaddingHorizontal,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (heading != null)
                _row(
                  context,
                  style,
                  Text(
                    heading,
                    style: textTheme.titleSmall?.copyWith(color: style.text),
                  ),
                ),
              if (heading != null && bodyText != null)
                const Gap.v(PillPalSpacing.xs),
              if (bodyText != null)
                heading == null ? _row(context, style, bodyText) : bodyText,
              if (actions.isNotEmpty) ...[
                const Gap.v(PillPalSpacing.md),
                // Text buttons take the tone's on-colour and read as actions
                // (bold, underlined); `action` itself is too weak on a fill.
                TextButtonTheme(
                  data:
                      TextButtonThemeData(style: _actionStyle(context, style)),
                  child: SizedBox(
                    width: double.infinity,
                    child: Wrap(
                      spacing: PillPalSpacing.sm,
                      runSpacing: PillPalSpacing.sm,
                      alignment: actionsAlignment,
                      children: actions,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  ButtonStyle _actionStyle(BuildContext context, _BannerStyle style) {
    final palette = context.palette;
    // Our values first; the app's text button theme fills in the rest (the
    // touch target).
    final themed = TextButtonTheme.of(context).style;
    final own = TextButton.styleFrom(
      foregroundColor: style.text,
      disabledForegroundColor: palette.inkMuted,
      overlayColor: style.text,
      textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
            decoration: TextDecoration.underline,
          ),
    );
    return themed == null ? own : own.merge(themed);
  }

  /// The first row: the icon, the [text] and the [trailing] widget.
  Widget _row(BuildContext context, _BannerStyle style, Widget text) {
    final iconData = icon ??
        switch (tone) {
          BannerTone.danger => Icons.error_outline,
          BannerTone.info => Icons.info_outline,
          BannerTone.soft => null,
        };
    final end = trailing;
    if (iconData == null && end == null) {
      return text;
    }
    return Row(
      crossAxisAlignment:
          end == null ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      children: [
        if (iconData != null) ...[
          // Decorative: the title or body names the problem in words.
          ExcludeSemantics(
            child: Icon(
              iconData,
              color: style.icon,
              // Grows with the text, but not past the senior icon size.
              size: math.min(
                MediaQuery.textScalerOf(context).scale(PillPalSizes.iconInline),
                PillPalSizes.iconSenior,
              ),
            ),
          ),
          const Gap.h(PillPalSpacing.md),
        ],
        Expanded(child: text),
        if (end != null) end,
      ],
    );
  }
}

/// Colours of one [BannerTone]: a soft fill with its matching on-colour.
class _BannerStyle {
  const _BannerStyle({required this.background, required this.text});

  factory _BannerStyle.of(BannerTone tone, PillPalPalette palette) {
    switch (tone) {
      case BannerTone.soft:
        return _BannerStyle(
          background: palette.actionSoft,
          text: palette.onActionSoft,
        );
      case BannerTone.info:
        return _BannerStyle(background: palette.raised, text: palette.ink);
      case BannerTone.danger:
        return _BannerStyle(
          background: palette.dangerSoft,
          text: palette.onDangerSoft,
        );
    }
  }

  final Color background;
  final Color text;

  /// The icon has the colour of the text.
  Color get icon => text;
}
