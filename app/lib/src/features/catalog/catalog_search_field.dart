import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';

/// The "find in the catalog" field of the medication form. It only opens
/// the search sheet: typing happens there, and so do the requests (on
/// submit, or after a pause in typing).
class CatalogSearchField extends StatelessWidget {
  /// Creates the field.
  const CatalogSearchField({required this.onTap, super.key});

  /// Opens the search sheet.
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Read-only: it opens the search sheet, so it says it is a button.
    return Semantics(
      button: true,
      excludeSemantics: true,
      label: l10n.catalogSearch,
      onTap: onTap,
      child: TextField(
        key: const Key('med-catalog'),
        readOnly: true,
        onTap: onTap,
        decoration: InputDecoration(
          hintText: l10n.catalogSearchFieldHint,
          prefixIcon: const Icon(Icons.search),
        ),
      ),
    );
  }
}
