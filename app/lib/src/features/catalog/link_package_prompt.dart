import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../theme/spacing.dart';
import '../common/choice_button.dart';
import '../common/gap.dart';
import '../common/show_pillpal_dialog.dart';
import 'catalog_providers.dart';
import 'consent_tiles.dart';

/// The answer to "link the package to the existing medication?" (D4).
class LinkPackageDecision {
  /// Creates a decision to link to [target].
  const LinkPackageDecision({required this.target, this.share = false});

  /// "Create separately" (also when the dialog was dismissed).
  static const LinkPackageDecision separate = LinkPackageDecision(target: null);

  /// The medication to link to; null for "create separately".
  final SameMedication? target;

  /// Whether the opt-in box was ticked in this prompt.
  final bool share;

  /// Whether to link the package to an existing medication.
  bool get link => target != null;
}

/// Asks whether the chosen product's package belongs to one of the
/// medications ([candidates], at least one) that have the same composition;
/// with several, the person picks which. [offerConsent] adds the opt-in box
/// (full-access roles, a scanned or typed shareable GTIN) unless the chosen
/// medication already counts the pair. Creating a separate medication is
/// always possible.
Future<LinkPackageDecision> showLinkPackagePrompt(
  BuildContext context, {
  required List<SameMedication> candidates,
  required bool offerConsent,
}) async {
  final decision = await showPillPalDialog<LinkPackageDecision>(
    context: context,
    barrierDismissible: false,
    builder: (context) =>
        LinkPackagePrompt(candidates: candidates, offerConsent: offerConsent),
  );
  return decision ?? LinkPackageDecision.separate;
}

/// The dialog of [showLinkPackagePrompt].
class LinkPackagePrompt extends StatefulWidget {
  /// Creates the dialog.
  const LinkPackagePrompt({
    required this.candidates,
    required this.offerConsent,
    super.key,
  });

  /// The medications with the same composition.
  final List<SameMedication> candidates;

  /// Whether the opt-in box may be shown.
  final bool offerConsent;

  @override
  State<LinkPackagePrompt> createState() => _LinkPackagePromptState();
}

class _LinkPackagePromptState extends State<LinkPackagePrompt> {
  bool _share = false;
  late SameMedication _target = widget.candidates.first;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final several = widget.candidates.length > 1;
    final showBox = widget.offerConsent && !_target.consented;
    return AlertDialog(
      key: const Key('catalog-link-prompt'),
      title: Text(l10n.catalogSameTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              several
                  ? l10n.catalogSamePromptMany
                  : l10n.catalogSamePrompt(_target.name),
            ),
            if (several)
              for (final candidate in widget.candidates) ...[
                const Gap.v(PillPalSpacing.sm),
                ChoiceButton(
                  key: ValueKey('catalog-link-choice-${candidate.id}'),
                  label: candidate.name,
                  selected: candidate.id == _target.id,
                  onTap: () => setState(() => _target = candidate),
                ),
              ],
            if (showBox)
              ConsentCheckboxTile(
                value: _share,
                onChanged: (ticked) => setState(() => _share = ticked),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('catalog-link-separate'),
          onPressed: () =>
              Navigator.of(context).pop(LinkPackageDecision.separate),
          child: Text(l10n.catalogSameSeparate),
        ),
        FilledButton(
          key: const Key('catalog-link-existing'),
          onPressed: () => Navigator.of(context).pop(
            LinkPackageDecision(target: _target, share: showBox && _share),
          ),
          child: Text(l10n.catalogSameLink),
        ),
      ],
    );
  }
}
