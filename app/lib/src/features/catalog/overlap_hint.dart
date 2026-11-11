import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/spacing.dart';
import '../common/banner_tone.dart';
import '../common/pillpal_banner.dart';
import '../common/pillpal_icon_button.dart';
import 'catalog_providers.dart';

/// The overlap hint of [query], shown only when another medication of the
/// profile shares a substance that has a display name in [names].
class OverlapHintSection extends ConsumerWidget {
  /// Creates the section.
  const OverlapHintSection({
    required this.query,
    required this.names,
    required this.onDismiss,
    super.key,
  });

  /// What is compared.
  final OverlapQuery query;

  /// Display names of substance ids.
  final Map<String, String> names;

  /// Called when the person closes the hint.
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shared = ref.watch(catalogOverlapProvider(query)).valueOrNull;
    final shownNames = [
      for (final id in shared ?? const <String>{})
        if (names[id] case final name?) name,
    ]..sort();
    if (shownNames.isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: PillPalSpacing.sm),
      child: OverlapHint(names: shownNames, onDismiss: onDismiss),
    );
  }
}

/// "Both contain: ...": a neutral note that a chosen product shares
/// substances with another medication of the profile (ADR 0015 §6, D9).
/// An info icon, no warning colour, no advice; it can be dismissed and
/// never blocks saving.
class OverlapHint extends StatelessWidget {
  /// Creates the hint for the substance [names].
  const OverlapHint({required this.names, required this.onDismiss, super.key});

  /// Display names of the shared substances.
  final List<String> names;

  /// Called when the person closes the hint.
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PillPalBanner(
      key: const Key('catalog-overlap'),
      tone: BannerTone.info,
      bodyKey: const Key('catalog-overlap-text'),
      body: l10n.catalogOverlap(names.join(', ')),
      trailing: PillPalIconButton(
        key: const Key('catalog-overlap-dismiss'),
        tooltip: l10n.catalogDismiss,
        icon: Icons.close,
        onPressed: onDismiss,
      ),
    );
  }
}
