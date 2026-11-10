import 'package:flutter/material.dart';

import '../../theme/spacing.dart';
import 'gap.dart';

/// Opens a bottom sheet in the app's look (rounded top and drag handle come
/// from the theme). The sheet may grow to the full height, so long content
/// scrolls inside [SheetScaffold]; resolves with the value popped.
Future<T?> showPillPalSheet<T>(BuildContext context, WidgetBuilder builder) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
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
    this.primaryAction,
    super.key,
  });

  /// Heading of the sheet.
  final String? title;

  /// Key of the title text, for tests.
  final Key? titleKey;

  /// The body.
  final List<Widget> children;

  /// The main button under the body.
  final Widget? primaryAction;

  @override
  Widget build(BuildContext context) {
    final heading = title;
    final action = primaryAction;
    return SafeArea(
      child: SingleChildScrollView(
        padding: PillPalSpacing.sheet.copyWith(
          bottom: PillPalSpacing.sheet.bottom +
              MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (heading != null) ...[
              Text(
                heading,
                key: titleKey,
                style: Theme.of(context).textTheme.titleLarge,
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
