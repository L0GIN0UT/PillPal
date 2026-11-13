import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../theme/app_theme.dart';
import '../../theme/motion.dart';
import '../../theme/spacing.dart';
import 'gap.dart';

/// Opens a bottom sheet in the app's look: radius 28 on top, the drag handle
/// and the 48 % scrim come from `bottomSheetTheme`. The sheet may grow to the
/// full height, so long content scrolls inside [SheetScaffold]; resolves with
/// the value popped. It slides up with the scrim in `slow` and closes in `base`
/// (B2-README "Motion").
Future<T?> showPillPalSheet<T>(BuildContext context, WidgetBuilder builder) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    sheetAnimationStyle: PillPalMotion.sheet,
    builder: builder,
  );
}

/// The content of a bottom sheet: an optional [title], the [children] in a
/// scrolling column, and a [primaryAction] (a full-width button) below; or,
/// with [SheetScaffold.fill], a [header] and a [body] in one fixed height.
/// Keeps clear of the system insets and the keyboard.
class SheetScaffold extends StatelessWidget {
  /// Creates the content.
  const SheetScaffold({
    required this.children,
    this.title,
    this.titleKey,
    this.liveTitle = false,
    this.primaryAction,
    super.key,
  })  : header = null,
        body = null;

  /// Creates content of one fixed height while the sheet is open: the space
  /// above the keyboard, at most [PillPalSizes.sheetMaxHeightFactor] of the
  /// screen. The [title] and the [header] (a search field) stay on top, and
  /// the [body] fills the rest, so the sheet does not jump as the body
  /// changes; a list in it scrolls inside. On a screen too short for
  /// [PillPalSizes.sheetMinContentHeight] the whole sheet scrolls.
  const SheetScaffold.fill({
    required Widget this.body,
    this.title,
    this.titleKey,
    this.liveTitle = false,
    this.header,
    super.key,
  })  : children = const [],
        primaryAction = null;

  /// Heading of the sheet.
  final String? title;

  /// Key of the title text, for tests.
  final Key? titleKey;

  /// Whether screen readers announce the title when the sheet's content
  /// changes to it (a state that appears in place, such as «Отчёт готов»).
  final bool liveTitle;

  /// The body.
  final List<Widget> children;

  /// The main button under the body.
  final Widget? primaryAction;

  /// What stays under the title of a [SheetScaffold.fill] sheet.
  final Widget? header;

  /// What fills the rest of a [SheetScaffold.fill] sheet.
  final Widget? body;

  @override
  Widget build(BuildContext context) {
    final fill = body;
    if (fill != null) {
      return _fixedHeight(context, fill);
    }
    final heading = title;
    final action = primaryAction;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    // The keyboard replaces the bottom safe area: one of the two, not both.
    return SafeArea(
      bottom: keyboard == 0,
      child: SingleChildScrollView(
        padding: PillPalSpacing.sheet.copyWith(
          bottom: PillPalSpacing.sheet.bottom + keyboard,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (heading != null) ...[
              _title(context, heading),
              const Gap.v(PillPalSpacing.md),
            ],
            ...children,
            if (action != null) ...[const Gap.v(PillPalSpacing.lg), action],
          ],
        ),
      ),
    );
  }

  Widget _fixedHeight(BuildContext context, Widget fill) {
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    // A factor, not `scale(height)`: a nonlinear scaler (Android 14) treats
    // its argument as a font size and would barely grow a large height.
    final minHeight =
        PillPalSizes.sheetMinContentHeight * media.textScaler.scale(1);
    final heading = title;
    final top = header;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: SizedBox(
        height: media.size.height * PillPalSizes.sheetMaxHeightFactor,
        // The keyboard replaces the bottom safe area: one of the two.
        child: SafeArea(
          top: false,
          bottom: keyboard == 0,
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              child: SizedBox(
                height: math.max(constraints.maxHeight, minHeight),
                child: Padding(
                  padding: PillPalSpacing.sheet,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (heading != null) ...[
                        _title(context, heading),
                        const Gap.v(PillPalSpacing.md),
                      ],
                      if (top != null) ...[
                        top,
                        const Gap.v(PillPalSpacing.md),
                      ],
                      Expanded(child: fill),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _title(BuildContext context, String heading) => Semantics(
        header: true,
        liveRegion: liveTitle,
        child: Text(
          heading,
          key: titleKey,
          style: Theme.of(context).textTheme.titleLarge,
        ),
      );
}
