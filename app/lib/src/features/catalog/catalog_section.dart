import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/api/api_exception.dart';
import '../../data/catalog/catalog_link.dart';
import '../../data/providers.dart';
import '../../data/repositories/local_writer.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import '../medications/medication_providers.dart';
import 'catalog_fill.dart';
import 'catalog_form_controller.dart';
import 'catalog_lang.dart';
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
    required this.fullAccess,
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

  /// Whether the role has full access (owner, guardian): only they get the
  /// opt-in box and the overlap hint; relatives who edit get neither.
  final bool fullAccess;

  /// Reads the text typed in a field of the form.
  final String Function(CatalogTextField field) readText;

  /// Sets the text of a field of the form.
  final void Function(CatalogTextField field, String value) writeText;

  /// The scan entry (4.11), shown above the search field.
  final Widget? scanAction;

  @override
  ConsumerState<CatalogSection> createState() => CatalogSectionState();
}

/// The state of [CatalogSection]. [selectProduct] is the entry point for
/// everything that picks a product: the search sheet here, and the scanner
/// and the manual GTIN entry of 4.11 (with their [GtinSource]).
class CatalogSectionState extends ConsumerState<CatalogSection> {
  CatalogFormController get _form => widget.controller;

  String get _lang => catalogLanguage(context);

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
    if (!widget.fullAccess ||
        _form.card == null ||
        _form.hintDismissed ||
        ids.isEmpty) {
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
    if (!widget.fullAccess) {
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
    if (_form.showConsentSwitch) {
      return [
        const Gap.v(PillPalSpacing.sm),
        ConsentActiveTile(
          value: _form.consentActive,
          onChanged: (on) =>
              on ? _form.resumeConsent() : _form.withdrawConsent(),
        ),
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
    await selectProduct(result.id);
  }

  /// Opens the card of [productId] and applies it to the form (or links the
  /// package to an existing medication, D4). [gtin] and [gtinSource] come
  /// from the scanner or the manual GTIN entry (4.11): only a scanned or
  /// typed GTIN makes the opt-in box appear. A text search passes neither.
  Future<void> selectProduct(
    String productId, {
    String? gtin,
    GtinSource gtinSource = GtinSource.catalog,
  }) async {
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
    final link = gtin == null ? pick.link : withGtin(pick.link, gtin);
    if (pick.same.isNotEmpty) {
      final linkHere = link.gtin;
      final decision = await showLinkPackagePrompt(
        context,
        candidates: pick.same,
        offerConsent: widget.fullAccess &&
            gtinSource != GtinSource.catalog &&
            linkHere != null &&
            isShareableGtin(linkHere),
      );
      if (!mounted) {
        return;
      }
      final target = decision.target;
      if (target != null) {
        await _linkExisting(target, pick, link, share: decision.share);
        return;
      }
    }
    _apply(pick, link, gtinSource);
  }

  /// D5: empty fields are filled, filled ones get an offer.
  void _apply(CatalogPick pick, CatalogLink link, GtinSource gtinSource) {
    final plan = planFill(
      pick.card,
      lang: _lang,
      current: {
        for (final field in CatalogTextField.values)
          field: widget.readText(field),
      },
    );
    plan.fills.forEach(widget.writeText);
    _form.select(link, pick.card, plan.offers, gtinSource: gtinSource);
  }

  /// D4: the package goes to the existing medication [existing]; no new row
  /// is made. A new medication's form is closed (nothing is lost); the form
  /// of an existing medication stays open with its unsaved edits.
  Future<void> _linkExisting(
    SameMedication existing,
    CatalogPick pick,
    CatalogLink link, {
    required bool share,
  }) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final cache = ref.read(catalogCacheRepositoryProvider);
    final service = ref.read(medicationServiceProvider);
    try {
      await service.linkPackage(
        existing.id,
        share ? withConsentTick(link) : link,
      );
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
    await rememberCardBestEffort(cache, pick.card);
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.catalogSameLinked(existing.name))),
    );
    if (mounted && widget.medicationId == null) {
      context.pop();
    }
  }
}
