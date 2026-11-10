import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/api_exception.dart';
import '../../data/providers.dart';
import '../../data/repositories/local_writer.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import '../medications/medication_providers.dart';
import 'catalog_fill.dart';
import 'catalog_form_controller.dart';
import 'catalog_providers.dart';
import 'catalog_search_field.dart';
import 'catalog_search_sheet.dart';
import 'catalog_section_parts.dart';
import 'consent_tiles.dart';
import 'link_package_prompt.dart';
import 'overlap_hint.dart';
import 'product_card.dart';

/// The catalog part of the medication form: search or the linked product,
/// "replace" offers, the overlap hint and the opt-in box (ADR 0015 §4-§6).
///
/// Free text stays authoritative: selecting a product fills empty fields
/// only (D5), and a chosen product with the composition of an existing
/// medication offers to link the package to it instead (D4). Selecting is
/// the only action that talks to the catalog, and only for the card.
class CatalogSection extends ConsumerStatefulWidget {
  /// Creates the section for the form whose state is [controller].
  const CatalogSection({
    required this.controller,
    required this.profileId,
    required this.medicationId,
    required this.canConsent,
    required this.readText,
    required this.writeText,
    this.scanAction,
    super.key,
  });

  /// The catalog state of the form.
  final CatalogFormController controller;

  /// The profile of the medication; null is the user's own.
  final String? profileId;

  /// The medication being edited; null for a new one.
  final String? medicationId;

  /// Whether the role may give the consent (full access only).
  final bool canConsent;

  /// Reads the text typed in a field of the form.
  final String Function(CatalogTextField field) readText;

  /// Sets the text of a field of the form.
  final void Function(CatalogTextField field, String value) writeText;

  /// The scan entry (4.11), shown above the search field.
  final Widget? scanAction;

  @override
  ConsumerState<CatalogSection> createState() => _CatalogSectionState();
}

class _CatalogSectionState extends ConsumerState<CatalogSection> {
  CatalogFormController get _form => widget.controller;

  String get _lang {
    final code = Localizations.localeOf(context).languageCode;
    return code == 'ru' ? 'ru' : 'en';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _form,
      builder: (context, child) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_form.isLinked) _linked() else ..._searchEntry(),
          for (final entry in _form.offers.entries)
            Padding(
              padding: const EdgeInsets.only(top: PillPalSpacing.sm),
              child: ReplaceOfferTile(
                field: entry.key,
                value: entry.value,
                onReplace: () => _replace(entry.key, entry.value),
                onKeep: () => _form.closeOffer(entry.key),
              ),
            ),
          ..._hint(),
          ..._consent(),
        ],
      ),
    );
  }

  List<Widget> _searchEntry() {
    final scan = widget.scanAction;
    return [
      if (scan != null) ...[scan, const Gap.v(PillPalSpacing.md)],
      CatalogSearchField(onTap: _openSearch),
    ];
  }

  Widget _linked() {
    final productId = _form.link.productId;
    return LinkedProductTile(
      name: _form.card?.product.name,
      onOpenCard: productId == null
          ? null
          : () => showProductCardSheet(context, productId),
      onUnlink: _form.unlink,
    );
  }

  List<Widget> _hint() {
    final ids = _form.substanceIds;
    if (_form.card == null || _form.hintDismissed || ids.isEmpty) {
      return const [];
    }
    return [
      OverlapHintSection(
        query: OverlapQuery(
          profileId: widget.profileId,
          excludeMedicationId: widget.medicationId,
          substanceIds: ids,
        ),
        names: _form.substanceNames(_lang),
        onDismiss: _form.dismissHint,
      ),
    ];
  }

  List<Widget> _consent() {
    if (!widget.canConsent) {
      return const [];
    }
    if (_form.canOfferConsent) {
      return [
        const Gap.v(PillPalSpacing.sm),
        ConsentCheckboxTile(
          value: _form.ticked,
          onChanged: (ticked) => _form.setTicked(value: ticked),
        ),
      ];
    }
    if (_form.consentActive) {
      return [
        const Gap.v(PillPalSpacing.sm),
        ConsentActiveTile(onOff: _form.withdrawConsent),
      ];
    }
    return const [];
  }

  void _replace(CatalogTextField field, String value) {
    widget.writeText(field, value);
    _form.closeOffer(field);
  }

  Future<void> _openSearch() async {
    final result = await showCatalogSearchSheet(context);
    if (result == null || !mounted) {
      return;
    }
    await _select(result.id);
  }

  Future<void> _select(String productId) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final CatalogPick pick;
    try {
      pick = await ref.read(catalogSelectionServiceProvider).pick(
            productId,
            profileId: widget.profileId,
            excludeMedicationId: widget.medicationId,
          );
    } on ApiException catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error.code == ApiException.networkError
                ? l10n.catalogSearchOffline
                : l10n.catalogSearchFailed,
          ),
        ),
      );
      return;
    }
    if (!mounted) {
      return;
    }
    final existing = pick.same.isEmpty ? null : pick.same.first;
    if (existing != null) {
      final gtin = pick.link.gtin;
      final decision = await showLinkPackagePrompt(
        context,
        name: existing.name,
        offerConsent: widget.canConsent &&
            !existing.consented &&
            gtin != null &&
            isShareableGtin(gtin),
      );
      if (!mounted) {
        return;
      }
      if (decision.link) {
        await _linkExisting(existing, pick, share: decision.share);
        return;
      }
    }
    _apply(pick);
  }

  /// D5: empty fields are filled, filled ones get an offer.
  void _apply(CatalogPick pick) {
    final plan = planFill(
      pick.card,
      lang: _lang,
      current: {
        for (final field in CatalogTextField.values)
          field: widget.readText(field),
      },
    );
    plan.fills.forEach(widget.writeText);
    _form.select(pick.link, pick.card, plan.offers);
  }

  /// D4: the package goes to the existing medication; no new row is made.
  Future<void> _linkExisting(
    SameMedication existing,
    CatalogPick pick, {
    required bool share,
  }) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final link = share ? withConsentTick(pick.link) : pick.link;
    try {
      await ref.read(medicationServiceProvider).linkPackage(existing.id, link);
      await ref.read(catalogCacheRepositoryProvider).remember(pick.card);
    } on DataException catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error.field == 'gtin_link_shared'
                ? l10n.catalogConsentUnavailable
                : l10n.errorGeneric,
          ),
        ),
      );
      return;
    }
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.catalogSameLinked(existing.name))),
    );
    if (mounted) {
      context.pop();
    }
  }
}
