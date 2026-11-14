import 'package:material_ui/material_ui.dart';

import 'pillpal_icon_button.dart';

/// The title of a sheet with the way to close it (B2-ScanCamera): the title
/// is a heading for screen readers, the close button carries [closeKey].
class SheetHeader extends StatelessWidget {
  /// Creates the header.
  const SheetHeader({required this.title, required this.closeKey, super.key});

  /// Heading of the sheet.
  final String title;

  /// Key of the close button, for tests and journeys.
  final Key closeKey;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Semantics(
            header: true,
            child: Text(title, style: Theme.of(context).textTheme.titleLarge),
          ),
        ),
        PillPalIconButton(
          key: closeKey,
          icon: Icons.close,
          tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ],
    );
  }
}
