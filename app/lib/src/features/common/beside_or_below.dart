import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../../theme/spacing.dart';

/// A title with its actions (docs/design.md, narrow screens 3): [trailing]
/// beside [main] while the whole of [main] fits on one line next to it, and
/// on its own line under [main], aligned to the end, when that makes [main]
/// one line or keeps a word of it whole (a Galaxy Z Fold cover screen), or
/// when [below] says so (the compact text scale). A title too long for the
/// line even alone keeps [trailing] beside: moving it would help nothing.
///
/// Beside, [main] takes the width that [trailing] leaves (like `Expanded`)
/// and both are centred on the line; below, [main] takes the whole width.
class BesideOrBelow extends MultiChildRenderObjectWidget {
  /// Creates the layout.
  BesideOrBelow({
    required Widget main,
    required Widget trailing,
    this.gap = PillPalSpacing.md,
    this.runGap = PillPalSpacing.sm,
    this.below = false,
    super.key,
  }) : super(children: [main, trailing]);

  /// Space between [main] and the trailing part on one line.
  final double gap;

  /// Space above the trailing part on its own line.
  final double runGap;

  /// Puts the trailing part under [main] whatever the width.
  final bool below;

  @override
  RenderBesideOrBelow createRenderObject(BuildContext context) =>
      RenderBesideOrBelow(
        gap: gap,
        runGap: runGap,
        below: below,
        textDirection: Directionality.of(context),
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderBesideOrBelow renderObject,
  ) {
    renderObject
      ..gap = gap
      ..runGap = runGap
      ..below = below
      ..textDirection = Directionality.of(context);
  }
}

/// Parent data of the children of [RenderBesideOrBelow].
class BesideOrBelowParentData extends ContainerBoxParentData<RenderBox> {}

/// The render object of [BesideOrBelow]: exactly two children, the main part
/// and the trailing part.
class RenderBesideOrBelow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, BesideOrBelowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, BesideOrBelowParentData> {
  /// Creates the render object.
  RenderBesideOrBelow({
    required double gap,
    required double runGap,
    required bool below,
    required TextDirection textDirection,
  })  : _gap = gap,
        _runGap = runGap,
        _below = below,
        _textDirection = textDirection;

  /// See [BesideOrBelow.gap].
  double get gap => _gap;
  double _gap;
  set gap(double value) {
    if (value != _gap) {
      _gap = value;
      markNeedsLayout();
    }
  }

  /// See [BesideOrBelow.runGap].
  double get runGap => _runGap;
  double _runGap;
  set runGap(double value) {
    if (value != _runGap) {
      _runGap = value;
      markNeedsLayout();
    }
  }

  /// See [BesideOrBelow.below].
  bool get below => _below;
  bool _below;
  set below(bool value) {
    if (value != _below) {
      _below = value;
      markNeedsLayout();
    }
  }

  /// Which end the trailing part sits at.
  TextDirection get textDirection => _textDirection;
  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value != _textDirection) {
      _textDirection = value;
      markNeedsLayout();
    }
  }

  RenderBox get _main => firstChild!;

  RenderBox get _trailing => lastChild!;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! BesideOrBelowParentData) {
      child.parentData = BesideOrBelowParentData();
    }
  }

  /// Whether both parts share one line [width] wide.
  bool _beside(double width) {
    if (_below) {
      return false;
    }
    if (!width.isFinite) {
      return true;
    }
    final line = _main.getMaxIntrinsicWidth(double.infinity);
    final beside =
        width - _gap - _trailing.getMaxIntrinsicWidth(double.infinity);
    if (line <= beside) {
      return true;
    }
    if (line <= width) {
      // One line on its own.
      return false;
    }
    // It wraps either way: move only if that keeps a word whole.
    final word = _main.getMinIntrinsicWidth(double.infinity);
    return !(word > beside && word <= width);
  }

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final width = constraints.maxWidth;
    Size place(RenderBox child, BoxConstraints childConstraints) {
      if (dry) {
        return child.getDryLayout(childConstraints);
      }
      child.layout(childConstraints, parentUsesSize: true);
      return child.size;
    }

    void position(RenderBox child, double x, double y) {
      if (!dry) {
        (child.parentData! as BesideOrBelowParentData).offset = Offset(x, y);
      }
    }

    final trailing = place(_trailing, BoxConstraints(maxWidth: width));
    final ltr = _textDirection == TextDirection.ltr;
    if (_beside(width)) {
      final mainWidth = width.isFinite
          ? math.max(0.0, width - _gap - trailing.width)
          : _main.getMaxIntrinsicWidth(double.infinity);
      final main = place(_main, BoxConstraints.tightFor(width: mainWidth));
      final total = mainWidth + _gap + trailing.width;
      final height = math.max(main.height, trailing.height);
      position(
          _main, ltr ? 0.0 : total - mainWidth, (height - main.height) / 2);
      position(
        _trailing,
        ltr ? total - trailing.width : 0.0,
        (height - trailing.height) / 2,
      );
      return constraints.constrain(Size(total, height));
    }
    final main = place(
      _main,
      width.isFinite
          ? BoxConstraints.tightFor(width: width)
          : const BoxConstraints(),
    );
    final total = math.max(main.width, trailing.width);
    position(_main, 0.0, 0.0);
    position(
      _trailing,
      ltr ? total - trailing.width : 0.0,
      main.height + _runGap,
    );
    return constraints.constrain(
      Size(total, main.height + _runGap + trailing.height),
    );
  }

  @override
  void performLayout() {
    size = _layout(constraints, dry: false);
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      _layout(constraints, dry: true);

  @override
  double computeMinIntrinsicWidth(double height) => math.max(
        _main.getMinIntrinsicWidth(height),
        _trailing.getMinIntrinsicWidth(height),
      );

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _main.getMaxIntrinsicWidth(height) +
      _gap +
      _trailing.getMaxIntrinsicWidth(height);

  double _height(double width, double Function(RenderBox, double) of) {
    if (_beside(width)) {
      final trailingWidth = _trailing.getMaxIntrinsicWidth(double.infinity);
      return math.max(
        of(_main, math.max(0.0, width - _gap - trailingWidth)),
        of(_trailing, width),
      );
    }
    return of(_main, width) + _runGap + of(_trailing, width);
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _height(width, (child, w) => child.getMinIntrinsicHeight(w));

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _height(width, (child, w) => child.getMaxIntrinsicHeight(w));

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) =>
      defaultComputeDistanceToFirstActualBaseline(baseline);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);
}
