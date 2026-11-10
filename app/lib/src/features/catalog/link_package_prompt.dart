import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import 'consent_tiles.dart';

/// The answer to "link the package to the existing medication?" (D4).
class LinkPackageDecision {
  /// Creates a decision.
  const LinkPackageDecision({required this.link, this.share = false});

  /// "Create separately" (also when the dialog was dismissed).
  static const LinkPackageDecision separate = LinkPackageDecision(link: false);

  /// Whether to link the package to the existing medication.
  final bool link;

  /// Whether the opt-in box was ticked in this prompt.
  final bool share;
}

/// Asks whether the chosen product's package belongs to the medication
/// [name] that has the same composition. [offerConsent] adds the opt-in
/// box (full-access roles, a shareable GTIN, a pair not counted yet).
/// Creating a separate medication is always possible.
Future<LinkPackageDecision> showLinkPackagePrompt(
  BuildContext context, {
  required String name,
  required bool offerConsent,
}) async {
  final decision = await showDialog<LinkPackageDecision>(
    context: context,
    barrierDismissible: false,
    builder: (context) =>
        LinkPackagePrompt(name: name, offerConsent: offerConsent),
  );
  return decision ?? LinkPackageDecision.separate;
}

/// The dialog of [showLinkPackagePrompt].
class LinkPackagePrompt extends StatefulWidget {
  /// Creates the dialog.
  const LinkPackagePrompt({
    required this.name,
    required this.offerConsent,
    super.key,
  });

  /// The existing medication.
  final String name;

  /// Whether the opt-in box is shown.
  final bool offerConsent;

  @override
  State<LinkPackagePrompt> createState() => _LinkPackagePromptState();
}

class _LinkPackagePromptState extends State<LinkPackagePrompt> {
  bool _share = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      key: const Key('catalog-link-prompt'),
      title: Text(l10n.catalogSameTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.catalogSamePrompt(widget.name)),
            if (widget.offerConsent)
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
        TextButton(
          key: const Key('catalog-link-existing'),
          onPressed: () => Navigator.of(context).pop(
            LinkPackageDecision(
              link: true,
              share: widget.offerConsent && _share,
            ),
          ),
          child: Text(l10n.catalogSameLink),
        ),
      ],
    );
  }
}
