import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/spacing.dart';
import '../catalog/catalog_fill.dart';
import '../catalog/catalog_form_controller.dart';
import '../catalog/catalog_section.dart';
import '../common/gap.dart';
import '../common/section_header.dart';

/// The top of the add form (board B2-AddMedication): the catalog section
/// with its two entry tiles and the search, then «Ввести вручную» as the
/// heading of the fields below for a new medication.
class MedicationCatalogBlock extends StatelessWidget {
  /// Creates the block for the form whose catalog state is [controller].
  const MedicationCatalogBlock({
    required this.controller,
    required this.profileId,
    required this.medicationId,
    required this.fullAccess,
    required this.autoScan,
    required this.nameFocus,
    required this.readText,
    required this.writeText,
    super.key,
  });

  /// The catalog state of the form.
  final CatalogFormController controller;

  /// The profile of the medication; null is the user's own.
  final String? profileId;

  /// The medication being edited; null for a new one.
  final String? medicationId;

  /// Whether the role has full access.
  final bool fullAccess;

  /// Whether to open the scanner once the form is shown.
  final bool autoScan;

  /// Focus of the name field: «Ввести вручную» puts the cursor there.
  final FocusNode nameFocus;

  /// Reads the text typed in a field of the form.
  final String Function(CatalogTextField field) readText;

  /// Sets the text of a field of the form.
  final void Function(CatalogTextField field, String value) writeText;

  @override
  Widget build(BuildContext context) {
    final isNew = medicationId == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CatalogSection(
          controller: controller,
          profileId: profileId,
          medicationId: medicationId,
          fullAccess: fullAccess,
          autoScan: autoScan && isNew,
          // The form below is the manual entry, so the tile takes the
          // cursor there; editing has no such tile.
          onManual: isNew ? nameFocus.requestFocus : null,
          readText: readText,
          writeText: writeText,
        ),
        if (isNew)
          SectionHeader(AppLocalizations.of(context).manualEntry)
        else
          const Gap.v(PillPalSpacing.xxl),
      ],
    );
  }
}
