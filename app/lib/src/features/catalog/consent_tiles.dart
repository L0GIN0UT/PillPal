import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/spacing.dart';
import '../common/icon_label.dart';
import '../common/pillpal_check_tile.dart';
import 'catalog_providers.dart';

/// The opt-in to count a (GTIN, product) link anonymously (ADR 0015 §4),
/// offered at link time only and never pre-ticked. It exists only while the
/// server accepts contributions (nothing is shown while that is unknown or
/// switched off), and can be ticked only online: offline it is disabled and
/// says it is available online.
class ConsentCheckboxTile extends ConsumerWidget {
  /// Creates the box.
  const ConsentCheckboxTile({
    required this.value,
    required this.onChanged,
    super.key,
  });

  /// Whether the box is ticked.
  final bool value;

  /// Called with the new value.
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final availability =
        ref.watch(contributionsAvailabilityProvider).valueOrNull;
    final available = availability == ContributionsAvailability.available;
    if (availability != ContributionsAvailability.available &&
        availability != ContributionsAvailability.offline) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PillPalCheckTile(
          tileKey: const Key('catalog-consent'),
          value: value,
          onChanged: available ? onChanged : null,
          title: l10n.catalogConsentLabel,
          subtitle: l10n.catalogConsentExplain,
        ),
        if (!available)
          Padding(
            padding: const EdgeInsets.only(bottom: PillPalSpacing.sm),
            child: IconLabel(
              key: const Key('catalog-consent-online-only'),
              icon: Icons.wifi_off,
              text: l10n.catalogConsentOnlineOnly,
            ),
          ),
      ],
    );
  }
}

/// The switch of a pair that is already counted: the way to stop it (the
/// explanation promises that it can be switched off when editing the
/// medication). After switching off it stays here, off, until the person
/// turns it on again.
class ConsentActiveTile extends StatelessWidget {
  /// Creates the switch.
  const ConsentActiveTile({
    required this.value,
    required this.onChanged,
    super.key,
  });

  /// Whether the pair is counted.
  final bool value;

  /// Called with the new value.
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SwitchListTile(
      key: const Key('catalog-consent-active'),
      contentPadding: EdgeInsets.zero,
      value: value,
      onChanged: onChanged,
      title: Text(l10n.catalogConsentLabel),
      subtitle: Text(l10n.catalogConsentExplain),
    );
  }
}
