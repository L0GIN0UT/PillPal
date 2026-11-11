import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/consents_dto.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import '../common/pillpal_card.dart';
import '../common/pillpal_check_tile.dart';
import 'consent_documents.dart';
import 'consent_text_sheet.dart';

/// A box was ticked or cleared.
typedef ConsentToggled = void Function(ConsentKind kind, {required bool value});

/// The consent boxes of B2-Consent: one checkbox per text, each ticked on its
/// own and never pre-ticked. Health data stands apart in a card of its own
/// with its explanation, the version and the link to the full text (ADR 0016,
/// privacy rule 6). Shared by the registration step and the re-consent gate.
class ConsentChecklist extends StatelessWidget {
  /// Creates the list for the texts in [documents] (baseline kinds only).
  const ConsentChecklist({
    required this.documents,
    required this.accepted,
    required this.onChanged,
    super.key,
  });

  /// The texts to show, by kind.
  final Map<ConsentKind, ConsentDocument> documents;

  /// The kinds ticked so far.
  final Set<ConsentKind> accepted;

  /// A box was ticked or cleared.
  final ConsentToggled onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final terms = documents[ConsentKind.terms];
    final privacy = documents[ConsentKind.privacy];
    final health = documents[ConsentKind.healthData];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (terms != null)
          _ConsentRow(
            checkboxKey: const Key('consent-terms'),
            linkKey: const Key('consent-text-terms'),
            label: l10n.consentTermsLabel,
            linkLabel: l10n.consentReadTerms,
            document: terms,
            ticked: accepted.contains(ConsentKind.terms),
            onChanged: onChanged,
          ),
        if (terms != null && privacy != null) const Gap.v(PillPalSpacing.md),
        if (privacy != null)
          _ConsentRow(
            checkboxKey: const Key('consent-privacy'),
            linkKey: const Key('consent-text-privacy'),
            label: l10n.consentPrivacyLabel,
            linkLabel: l10n.consentReadPrivacy,
            document: privacy,
            ticked: accepted.contains(ConsentKind.privacy),
            onChanged: onChanged,
          ),
        if (health != null) ...[
          const Gap.v(PillPalSpacing.lg),
          PillPalCard(
            key: const Key('consent-health-card'),
            child: _ConsentRow(
              checkboxKey: const Key('consent-health'),
              linkKey: const Key('consent-text-health'),
              label: l10n.consentHealthTitle,
              body: l10n.consentHealthBody,
              linkLabel: l10n.consentReadHealth,
              document: health,
              ticked: accepted.contains(ConsentKind.healthData),
              onChanged: onChanged,
              showVersion: true,
            ),
          ),
        ],
      ],
    );
  }
}

class _ConsentRow extends StatelessWidget {
  const _ConsentRow({
    required this.checkboxKey,
    required this.linkKey,
    required this.label,
    required this.linkLabel,
    required this.document,
    required this.ticked,
    required this.onChanged,
    this.body,
    this.showVersion = false,
  });

  final Key checkboxKey;
  final Key linkKey;
  final String label;
  final String? body;
  final String linkLabel;
  final ConsentDocument document;
  final bool ticked;
  final bool showVersion;
  final ConsentToggled onChanged;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return PillPalCheckTile(
      tileKey: checkboxKey,
      value: ticked,
      onChanged: (value) => onChanged(document.kind, value: value),
      title: label,
      subtitle: body,
      emphasized: showVersion,
      // Under the label, so the link and the version start where it does.
      footer: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            key: linkKey,
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            onPressed: () => showConsentTextSheet(context, document),
            child: Text(linkLabel),
          ),
        ),
        if (showVersion)
          Text(
            consentVersionLine(context, document),
            key: const Key('consent-health-version'),
            style: textTheme.bodySmall,
          ),
      ],
    );
  }
}
