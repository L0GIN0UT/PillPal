import 'package:flutter/material.dart';

import '../../theme/spacing.dart';
import 'gap.dart';

/// Opens a bottom sheet in the app's look: radius 28 on top, the drag handle
/// and the 48 % scrim come from `bottomSheetTheme`. The sheet may grow to the
/// full height, so long content scrolls inside [SheetScaffold]; resolves with
/// the value popped.
Future<T?> showPillPalSheet<T>(BuildContext context, WidgetBuilder builder) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: builder,
  );
}

/// The content of a bottom sheet: an optional [title], the [children] in a
/// scrolling column, and a [primaryAction] (a full-width button) below.
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
  });

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

  @override
  Widget build(BuildContext context) {
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
              Semantics(
                header: true,
                liveRegion: liveTitle,
                child: Text(
                  heading,
                  key: titleKey,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const Gap.v(PillPalSpacing.md),
            ],
            ...children,
            if (action != null) ...[const Gap.v(PillPalSpacing.lg), action],
          ],
        ),
      ),
    );
  }
}
