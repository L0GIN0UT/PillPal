import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import 'sheet_scaffold.dart';

/// One person in a profile picker: an opaque id and the name to show.
@immutable
class ProfileChipItem {
  /// Creates an item.
  const ProfileChipItem({required this.id, required this.label});

  /// Id of the profile; passed back to `onSelected`.
  final String id;

  /// Name or short label of the person.
  final String label;
}

/// The sheet that lists everyone the account may see, with the shown person
/// checked. Picking a row closes the sheet and calls [onSelected]. A row has
/// the key `<keyPrefix>-<id>`. Shared by the «Все N» chip and the profile
/// button of the header.
Future<void> showProfilePickerSheet(
  BuildContext context, {
  required List<ProfileChipItem> items,
  required String selectedId,
  required ValueChanged<String> onSelected,
  required String keyPrefix,
}) {
  final title = AppLocalizations.of(context).profilesSheetTitle;
  return showPillPalSheet<void>(
    context,
    (sheetContext) => SheetScaffold(
      title: title,
      children: [
        for (final item in items)
          ListTile(
            key: ValueKey('$keyPrefix-${item.id}'),
            minTileHeight: sheetContext.metrics.touchTarget,
            selected: item.id == selectedId,
            title: Text(item.label),
            trailing: item.id == selectedId ? const Icon(Icons.check) : null,
            onTap: () {
              Navigator.of(sheetContext).pop();
              onSelected(item.id);
            },
          ),
      ],
    ),
  );
}
