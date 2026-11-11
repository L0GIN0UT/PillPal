import 'package:flutter/material.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/consents_dto.dart';
import '../../theme/spacing.dart';
import '../common/formatters.dart';
import '../common/gap.dart';
import '../common/sheet_scaffold.dart';
import 'consent_documents.dart';

/// Opens the text of [document] in a sheet (not a route), so it reads the
/// same on the registration screens and on the consent gate and leaves the
/// screen below as it was.
Future<void> showConsentTextSheet(
  BuildContext context,
  ConsentDocument document,
) {
  return showPillPalSheet<void>(
    context,
    (context) => _ConsentTextSheet(document: document),
  );
}

/// «Version of 1 Nov 2026» for [document], in the language of [context].
String consentVersionLine(BuildContext context, ConsentDocument document) {
  final l10n = AppLocalizations.of(context);
  final locale = Localizations.localeOf(context).toLanguageTag();
  return l10n.consentVersionLine(
    formatShortDate(document.effectiveFrom, locale),
  );
}

class _ConsentTextSheet extends StatelessWidget {
  const _ConsentTextSheet({required this.document});

  final ConsentDocument document;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final textTheme = Theme.of(context).textTheme;
    final (title, body) = switch (document.kind) {
      ConsentKind.terms => (
          l10n.consentTextTitleTerms,
          l10n.consentTextBodyTerms,
        ),
      ConsentKind.privacy => (
          l10n.consentTextTitlePrivacy,
          l10n.consentTextBodyPrivacy,
        ),
      ConsentKind.healthData => (
          l10n.consentTextTitleHealth,
          l10n.consentTextBodyHealth,
        ),
      // Never offered at registration; the text is the one of the medication
      // form (ADR 0015 §4).
      ConsentKind.catalogContribution => (
          l10n.catalogConsentLabel,
          l10n.catalogConsentExplain,
        ),
    };
    return SheetScaffold(
      title: title,
      titleKey: const Key('consent-text-title'),
      primaryAction: FilledButton(
        key: const Key('consent-text-close'),
        onPressed: () => Navigator.of(context).pop(),
        child: Text(l10n.consentTextClose),
      ),
      children: [
        Text(consentVersionLine(context, document), style: textTheme.bodySmall),
        const Gap.v(PillPalSpacing.md),
        Text(body, key: const Key('consent-text-body')),
      ],
    );
  }
}
