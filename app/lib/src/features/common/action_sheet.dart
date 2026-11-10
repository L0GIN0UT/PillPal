import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';

/// One row of an [ActionSheet]. Plain data: [key] goes to the tappable tile,
/// so tests find and tap the row itself.
@immutable
class ActionSheetItem {
  /// Creates a row.
  const ActionSheetItem({
    required this.title,
    required this.onTap,
    this.icon,
    this.subtitle,
    this.trailing,
    this.destructive = false,
    this.key,
  });

  /// Label of the action.
  final String title;

  /// Called on tap (the caller closes the sheet).
  final VoidCallback onTap;

  /// Leading icon.
  final IconData? icon;

  /// A second line.
  final String? subtitle;

  /// A widget at the end, such as a chevron.
  final Widget? trailing;

  /// Whether the action deletes or discards something (danger colour).
  final bool destructive;

  /// Key of the tile.
  final Key? key;
}

/// A bottom sheet of actions (a dose menu, a choice among doses): an optional
/// heading with a second line, then one tile per [ActionSheetItem]. Tiles are
/// at least as tall as a touch target of the mode (64 in senior mode). Show it
/// with `showPillPalSheet`.
class ActionSheet extends StatelessWidget {
  /// Creates the sheet content.
  const ActionSheet({
    required this.items,
    this.title,
    this.subtitle,
    super.key,
  });

  /// Heading.
  final String? title;

  /// Second line of the heading.
  final String? subtitle;

  /// The actions.
  final List<ActionSheetItem> items;

  /// The same side edge as `SheetScaffold`.
  static const EdgeInsets _padding =
      EdgeInsets.symmetric(horizontal: PillPalSpacing.xl);

  @override
  Widget build(BuildContext context) {
    final heading = title;
    final detail = subtitle;
    final minHeight = context.metrics.touchTarget;
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (heading != null)
              ListTile(
                contentPadding: _padding,
                title: Semantics(
                  header: true,
                  child: Text(
                    heading,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                subtitle: detail == null ? null : Text(detail),
              ),
            for (final item in items) _tile(context, item, minHeight),
          ],
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, ActionSheetItem item, double minHeight) {
    final icon = item.icon;
    final subtitle = item.subtitle;
    final color = item.destructive ? context.palette.danger : null;
    return ListTile(
      key: item.key,
      contentPadding: _padding,
      minTileHeight: minHeight,
      leading: icon == null ? null : Icon(icon, color: color),
      title: Text(
        item.title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(color: color),
      ),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: item.trailing,
      onTap: item.onTap,
    );
  }
}
