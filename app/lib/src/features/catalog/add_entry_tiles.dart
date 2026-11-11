import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/radius.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';

/// The two ways into the add form (board B2-AddMedication): «Сканировать
/// упаковку» as a tonal tile and «Ввести вручную» as a secondary one, side
/// by side, or one under the other from x1.25 of text. [onManual] is null
/// when the form is not for a new medication: there is no manual entry to
/// start, so the scan tile stands alone.
///
/// The keys are `catalog-scan` and `catalog-manual`.
class AddEntryTiles extends StatelessWidget {
  /// Creates the tiles.
  const AddEntryTiles({required this.onScan, this.onManual, super.key});

  /// Opens the scan sheet.
  final VoidCallback onScan;

  /// Puts the cursor in the name field; null hides the tile.
  final VoidCallback? onManual;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final palette = context.palette;
    final manual = onManual;
    const shape = RoundedRectangleBorder(borderRadius: PillPalRadius.card);
    const tile = ButtonStyle(
      shape: WidgetStatePropertyAll(shape),
      minimumSize: WidgetStatePropertyAll(Size(0, PillPalSizes.entryTileMin)),
      padding: WidgetStatePropertyAll(
        EdgeInsets.symmetric(
          horizontal: PillPalSpacing.sm,
          vertical: PillPalSpacing.md,
        ),
      ),
    );
    final scan = FilledButton(
      key: const Key('catalog-scan'),
      onPressed: onScan,
      style: tile.merge(
        FilledButton.styleFrom(
          backgroundColor: palette.actionSoft,
          foregroundColor: palette.onActionSoft,
        ),
      ),
      child: _Tile(Icons.qr_code_scanner, l10n.scanPackageAction),
    );
    if (manual == null) {
      return scan;
    }
    final write = OutlinedButton(
      key: const Key('catalog-manual'),
      onPressed: manual,
      style: tile,
      child: _Tile(Icons.edit_outlined, l10n.manualEntry),
    );
    if (context.stacksPair) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [scan, const Gap.v(PillPalSpacing.md), write],
      );
    }
    // Equal tiles even when one label wraps and the other does not.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: scan),
          const Gap.h(PillPalSpacing.md),
          Expanded(child: write),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.icon, this.label);

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(child: Icon(icon)),
        const Gap.v(PillPalSpacing.sm),
        Text(label, textAlign: TextAlign.center),
      ],
    );
  }
}
