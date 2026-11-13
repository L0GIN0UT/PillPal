import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/catalog/catalog_search_dto.dart';
import '../../data/config.dart';
import '../../theme/app_theme.dart';
import '../../theme/palette.dart';
import '../../theme/spacing.dart';
import '../common/compact_rows.dart';
import '../common/gap.dart';
import '../common/pillpal_card.dart';
import '../common/pillpal_icon_button.dart';
import '../common/sheet_scaffold.dart';
import '../common/status_message.dart';
import 'catalog_lang.dart';
import 'catalog_providers.dart';
import 'catalog_result_tile.dart';
import 'catalog_search_controller.dart';

/// The catalog kinds a search can look for.
abstract final class CatalogSearchKind {
  /// Products (medications), the form's search.
  static const String product = 'product';

  /// Substances, for the manual composition.
  static const String substance = 'substance';
}

/// Opens the search sheet; the result is the row the person tapped, null
/// when they closed it.
Future<SearchResult?> showCatalogSearchSheet(
  BuildContext context, {
  String kind = CatalogSearchKind.product,
}) {
  return showPillPalSheet<SearchResult>(
    context,
    (context) => CatalogSearchSheet(kind: kind),
  );
}

/// Search of the catalog. A request is made when the person submits and
/// after a pause in typing (ADR 0015 §3); offline the sheet says so and
/// offers no search until they retry.
class CatalogSearchSheet extends ConsumerStatefulWidget {
  /// Creates the sheet for [kind] (a [CatalogSearchKind]).
  const CatalogSearchSheet({required this.kind, super.key});

  /// What is searched.
  final String kind;

  @override
  ConsumerState<CatalogSearchSheet> createState() => _CatalogSearchState();
}

class _CatalogSearchState extends ConsumerState<CatalogSearchSheet> {
  final TextEditingController _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _run() {
    // The controller reports every outcome through its state.
    unawaited(
      ref.read(catalogSearchProvider.notifier).search(
            _text.text,
            lang: catalogLanguage(context),
            kind: widget.kind,
          ),
    );
  }

  void _typed(String text) {
    // Searched after the debounce pause, never when too short.
    ref.read(catalogSearchProvider.notifier).typed(
          text,
          lang: catalogLanguage(context),
          kind: widget.kind,
        );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(catalogSearchProvider);
    final isProduct = widget.kind == CatalogSearchKind.product;
    // One height while the sheet is open, so it does not jump as the body
    // switches between a message, a spinner and results.
    return SheetScaffold.fill(
      title: isProduct ? l10n.catalogSearch : l10n.catalogSubstanceSearch,
      header: _field(
        l10n,
        offline: state.status == CatalogSearchStatus.offline,
        isProduct: isProduct,
      ),
      body: KeyedSubtree(
        key: const Key('catalog-search-area'),
        child: _body(l10n, state),
      ),
    );
  }

  Widget _field(
    AppLocalizations l10n, {
    required bool offline,
    required bool isProduct,
  }) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            key: const Key('catalog-search-text'),
            controller: _text,
            enabled: !offline,
            autofocus: true,
            textInputAction: TextInputAction.search,
            inputFormatters: [
              LengthLimitingTextInputFormatter(CatalogPolicy.searchMaxLength),
            ],
            onChanged: _typed,
            onSubmitted: (_) => _run(),
            decoration: InputDecoration(
              hintText: isProduct
                  ? l10n.catalogSearchFieldHint
                  : l10n.catalogSearchSubstanceHint,
            ),
          ),
        ),
        const Gap.h(PillPalSpacing.sm),
        PillPalIconButton(
          key: const Key('catalog-search-go'),
          tooltip: l10n.catalogSearchAction,
          icon: Icons.search,
          onPressed: offline ? null : _run,
        ),
      ],
    );
  }

  Widget _body(AppLocalizations l10n, CatalogSearchState state) {
    switch (state.status) {
      case CatalogSearchStatus.idle:
        return _message(
          StatusMessage(icon: Icons.info_outline, text: l10n.catalogDataNote),
        );
      case CatalogSearchStatus.loading:
        return _loading(l10n, state.results);
      case CatalogSearchStatus.tooShort:
        return _message(
          StatusMessage(
            key: const Key('catalog-too-short'),
            icon: Icons.edit_outlined,
            text: l10n.catalogSearchTooShort,
          ),
        );
      case CatalogSearchStatus.failed:
        return _message(
          StatusMessage(
            key: const Key('catalog-failed'),
            icon: Icons.error_outline,
            text: l10n.catalogSearchFailed,
          ),
        );
      case CatalogSearchStatus.offline:
        return _message(
          StatusMessage(
            key: const Key('catalog-offline'),
            icon: Icons.wifi_off,
            text: l10n.catalogSearchOffline,
            action: TextButton(
              key: const Key('catalog-retry'),
              onPressed: ref.read(catalogSearchProvider.notifier).reset,
              child: Text(l10n.catalogRetry),
            ),
          ),
        );
      case CatalogSearchStatus.loaded:
        return _results(l10n, state.results);
    }
  }

  /// The spinner on the first search; while typing refines it, the earlier
  /// results stay under a thin bar instead of flickering away.
  Widget _loading(AppLocalizations l10n, List<SearchResult> earlier) {
    if (earlier.isEmpty) {
      return const Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.only(top: PillPalSpacing.lg),
          child: CircularProgressIndicator(),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const LinearProgressIndicator(key: Key('catalog-loading-bar')),
        const Gap.v(PillPalSpacing.sm),
        Expanded(child: _results(l10n, earlier)),
      ],
    );
  }

  Widget _results(AppLocalizations l10n, List<SearchResult> results) {
    if (results.isEmpty) {
      return _message(
        StatusMessage(
          key: const Key('catalog-empty'),
          icon: Icons.search_off,
          text: l10n.catalogSearchEmpty,
        ),
      );
    }
    final market = ref.watch(catalogOwnMarketProvider);
    final divider = Divider(
      height: PillPalSizes.hairline,
      thickness: PillPalSizes.hairline,
      color: context.palette.border,
    );
    final tiles = [
      for (final result in results)
        CatalogResultTile(
          result: result,
          foreign: widget.kind == CatalogSearchKind.product &&
              result.market != market,
          onTap: () => Navigator.of(context).pop(result),
        ),
    ];
    // The card is as tall as its rows, at most the area; they scroll in it.
    // Its rows take the narrow layout together (docs/design.md).
    return Align(
      alignment: Alignment.topCenter,
      child: CompactGroup(
        rows: tiles,
        child: PillPalCard(
          padding: EdgeInsets.zero,
          child: ListView.separated(
            key: const Key('catalog-results'),
            shrinkWrap: true,
            itemCount: tiles.length,
            separatorBuilder: (context, index) => divider,
            itemBuilder: (context, index) => tiles[index],
          ),
        ),
      ),
    );
  }

  /// A message at the top of the area, scrolling when the area is short.
  Widget _message(Widget message) => SingleChildScrollView(child: message);
}
