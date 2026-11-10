import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/gen/app_localizations.dart';
import '../../data/catalog/catalog_search_dto.dart';
import '../../data/config.dart';
import '../../theme/spacing.dart';
import '../common/gap.dart';
import '../common/info_note.dart';
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
  return showModalBottomSheet<SearchResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => CatalogSearchSheet(kind: kind),
  );
}

/// Search of the catalog. A request is made only when the person submits;
/// offline the sheet says so and offers no search until they retry.
class CatalogSearchSheet extends ConsumerStatefulWidget {
  /// Creates the sheet for [kind] (a [CatalogSearchKind]).
  const CatalogSearchSheet({required this.kind, super.key});

  /// What is searched.
  final String kind;

  @override
  ConsumerState<CatalogSearchSheet> createState() => _CatalogSearchState();
}

class _CatalogSearchState extends ConsumerState<CatalogSearchSheet> {
  static const double _heightFactor = 0.9;

  final TextEditingController _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _run() {
    final lang = Localizations.localeOf(context).languageCode;
    // The controller reports every outcome through its state.
    unawaited(
      ref.read(catalogSearchProvider.notifier).search(
            _text.text,
            lang: lang == 'ru' ? 'ru' : 'en',
            kind: widget.kind,
          ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(catalogSearchProvider);
    final offline = state.status == CatalogSearchStatus.offline;
    final isProduct = widget.kind == CatalogSearchKind.product;
    final insets = MediaQuery.viewInsetsOf(context);
    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * _heightFactor,
        ),
        child: Padding(
          padding: PillPalSpacing.sheet,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                isProduct ? l10n.catalogSearch : l10n.catalogSubstanceSearch,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Gap.v(PillPalSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      key: const Key('catalog-search-text'),
                      controller: _text,
                      enabled: !offline,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      inputFormatters: [
                        LengthLimitingTextInputFormatter(
                          CatalogPolicy.searchMaxLength,
                        ),
                      ],
                      onSubmitted: (_) => _run(),
                      decoration: InputDecoration(
                        hintText: isProduct
                            ? l10n.catalogSearchFieldHint
                            : l10n.catalogSearchSubstanceHint,
                      ),
                    ),
                  ),
                  const Gap.h(PillPalSpacing.sm),
                  IconButton(
                    key: const Key('catalog-search-go'),
                    tooltip: l10n.catalogSearchAction,
                    icon: const Icon(Icons.search),
                    onPressed: offline ? null : _run,
                  ),
                ],
              ),
              const Gap.v(PillPalSpacing.md),
              Flexible(child: _body(l10n, state)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(AppLocalizations l10n, CatalogSearchState state) {
    final textTheme = Theme.of(context).textTheme;
    switch (state.status) {
      case CatalogSearchStatus.idle:
        return Text(l10n.catalogDataNote, style: textTheme.bodySmall);
      case CatalogSearchStatus.loading:
        return const Center(
          heightFactor: 1,
          child: CircularProgressIndicator(),
        );
      case CatalogSearchStatus.tooShort:
        return Text(
          l10n.catalogSearchTooShort,
          key: const Key('catalog-too-short'),
        );
      case CatalogSearchStatus.failed:
        return Text(
          l10n.catalogSearchFailed,
          key: const Key('catalog-failed'),
        );
      case CatalogSearchStatus.offline:
        return _offline(l10n);
      case CatalogSearchStatus.loaded:
        return _results(l10n, state.results);
    }
  }

  Widget _offline(AppLocalizations l10n) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InfoNote(
          key: const Key('catalog-offline'),
          text: l10n.catalogSearchOffline,
        ),
        const Gap.v(PillPalSpacing.sm),
        TextButton(
          key: const Key('catalog-retry'),
          onPressed: ref.read(catalogSearchProvider.notifier).reset,
          child: Text(l10n.catalogRetry),
        ),
      ],
    );
  }

  Widget _results(AppLocalizations l10n, List<SearchResult> results) {
    if (results.isEmpty) {
      return Text(l10n.catalogSearchEmpty, key: const Key('catalog-empty'));
    }
    final market = ref.watch(catalogOwnMarketProvider);
    return ListView.separated(
      key: const Key('catalog-results'),
      shrinkWrap: true,
      itemCount: results.length,
      separatorBuilder: (context, index) => const Gap.v(PillPalSpacing.sm),
      itemBuilder: (context, index) {
        final result = results[index];
        return CatalogResultTile(
          result: result,
          foreign: widget.kind == CatalogSearchKind.product &&
              result.market != market,
          onTap: () => Navigator.of(context).pop(result),
        );
      },
    );
  }
}
