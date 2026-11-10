import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/radius.dart';
import '../../theme/spacing.dart';
import 'gap.dart';

/// The longest a segment label may get before the control gives up and shows
/// a radio list (B2-README `segmented`): at three lines a segment is a tall
/// narrow column that nobody can read.
const int _maxSegmentLines = 2;

/// A segmented control of a few exclusive choices, on a `raised` stadium
/// track with the selected segment lifted on `surface` and set in 700 weight.
/// A label that would wrap to three lines at the current text scale and width,
/// or a word wider than its segment, turns the whole control into a radio
/// list, measured with [TextPainter], so the choice stays readable at 320 px
/// and text x2.0 in Russian.
///
/// [options] keeps its order and must not be empty; [selected] must be one of
/// them. Give [key] to the control; [keyOf] gives each option its key
/// (`reminder-level-quiet`): on the label inside the segment (a tap on it
/// reaches the segment; the framework's button cannot be wrapped) and on the
/// whole tappable row in the list layout.
///
/// It measures text in a `LayoutBuilder`, so it cannot sit inside an
/// `IntrinsicWidth` or `IntrinsicHeight`.
class PillPalSegmented<T> extends StatelessWidget {
  /// Creates the control.
  const PillPalSegmented({
    required this.options,
    required this.selected,
    required this.onChanged,
    this.keyOf,
    super.key,
  });

  /// Values and their labels, in display order.
  final Map<T, String> options;

  /// The current value; one of the [options].
  final T selected;

  /// Called with the value the user picks.
  final ValueChanged<T> onChanged;

  /// Key of the option of a value.
  final Key? Function(T value)? keyOf;

  @override
  Widget build(BuildContext context) {
    assert(options.isNotEmpty, 'a segmented control needs options');
    assert(options.containsKey(selected), 'selected must be one of options');
    return LayoutBuilder(
      builder: (context, constraints) {
        final fits = constraints.hasBoundedWidth &&
            _labelsFit(context, constraints.maxWidth);
        return fits ? _track(context) : _radioList(context);
      },
    );
  }

  /// Whether every label stays within [_maxSegmentLines] lines in its
  /// segment and no single word is wider than the segment (a word cannot
  /// wrap, so it would be cut). The segment is the width of the control, less
  /// the track and the gaps, shared by the segments, less the padding of one.
  bool _labelsFit(BuildContext context, double width) {
    // The selected segment is the widest.
    final style = Theme.of(context).textTheme.segmentLabel(selected: true);
    final segmentWidth = math.max(
      0.0,
      (width -
                  2 * PillPalSpacing.xs -
                  (options.length - 1) * PillPalSpacing.xs) /
              options.length -
          2 * PillPalSpacing.sm,
    );
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    double widthOf(String text, double max) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: direction,
        textScaler: scaler,
      )..layout(maxWidth: max);
      final lines = painter.computeLineMetrics().length;
      final longest = painter.width;
      painter.dispose();
      return lines > _maxSegmentLines ? double.infinity : longest;
    }

    for (final label in options.values) {
      if (widthOf(label, segmentWidth) > segmentWidth) {
        return false;
      }
      for (final word in label.split(RegExp(r'\s+'))) {
        // Unbounded: the width the word needs on one line.
        if (widthOf(word, double.infinity) > segmentWidth) {
          return false;
        }
      }
    }
    return true;
  }

  /// Vertical padding that makes a segment a touch target high: the button
  /// of the framework is only as tall as its text and padding.
  double _segmentPadding(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    final line = MediaQuery.textScalerOf(context).scale(style?.fontSize ?? 0) *
        (style?.height ?? 1);
    return math.max(
        PillPalSpacing.sm, (context.metrics.touchTarget - line) / 2);
  }

  Widget _track(BuildContext context) {
    final palette = context.palette;
    return DecoratedBox(
      decoration: ShapeDecoration(
        color: palette.raised,
        shape: PillPalRadius.pill,
      ),
      child: Padding(
        padding: const EdgeInsets.all(PillPalSpacing.xs),
        child: SegmentedButton<T>(
          showSelectedIcon: false,
          segments: [
            for (final entry in options.entries)
              ButtonSegment<T>(
                value: entry.key,
                label: Text(
                  entry.value,
                  key: keyOf?.call(entry.key),
                  textAlign: TextAlign.center,
                ),
              ),
          ],
          selected: {selected},
          onSelectionChanged: (values) => onChanged(values.single),
          style: ButtonStyle(
            // The track draws the edge; the theme's interim border goes.
            side: const WidgetStatePropertyAll(BorderSide.none),
            padding: WidgetStatePropertyAll(
              EdgeInsets.symmetric(
                horizontal: PillPalSpacing.sm,
                vertical: _segmentPadding(context),
              ),
            ),
            backgroundColor: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.selected)
                  ? palette.surface
                  : Colors.transparent,
            ),
          ),
        ),
      ),
    );
  }

  Widget _radioList(BuildContext context) {
    return Column(
      key: const Key('segmented-radio-list'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in options.entries)
          _RadioRow(
            key: keyOf?.call(entry.key),
            label: entry.value,
            selected: entry.key == selected,
            onTap: () => onChanged(entry.key),
          ),
      ],
    );
  }
}

/// One row of the radio-list layout: the radio mark and the whole label.
class _RadioRow extends StatelessWidget {
  const _RadioRow({
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Semantics(
      label: label,
      button: true,
      inMutuallyExclusiveGroup: true,
      checked: selected,
      onTap: onTap,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: context.metrics.touchTarget),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: PillPalSpacing.sm),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: PillPalSizes.iconInline,
                  color: selected ? palette.action : palette.outline,
                ),
                const Gap.h(PillPalSpacing.md),
                Expanded(
                  child: Text(
                    label,
                    style: Theme.of(context)
                        .textTheme
                        .radioLabel(selected: selected),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
