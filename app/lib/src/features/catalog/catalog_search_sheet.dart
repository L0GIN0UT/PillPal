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
import '../common/gap.dart';
import '../common/pillpal_card.dart';
import '../common/pillpal_icon_button.dart';
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
    // The controller reports every outcome through its state.
    unawaited(
      ref.read(catalogSearchProvider.notifier).search(
            _text.text,
            lang: catalogLanguage(context),
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
                  PillPalIconButton(
                    key: const Key('catalog-search-go'),
                    tooltip: l10n.catalogSearchAction,
                    icon: Icons.search,
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
    switch (state.status) {
      case CatalogSearchStatus.idle:
        return StatusMessage(
          icon: Icons.info_outline,
          text: l10n.catalogDataNote,
        );
      case CatalogSearchStatus.loading:
        return const Center(
          heightFactor: 1,
          child: CircularProgressIndicator(),
        );
      case CatalogSearchStatus.tooShort:
        return StatusMessage(
          key: const Key('catalog-too-short'),
          icon: Icons.edit_outlined,
          text: l10n.catalogSearchTooShort,
        );
      case CatalogSearchStatus.failed:
        return StatusMessage(
          key: const Key('catalog-failed'),
          icon: Icons.error_outline,
          text: l10n.catalogSearchFailed,
        );
      case CatalogSearchStatus.offline:
        return StatusMessage(
          key: const Key('catalog-offline'),
          icon: Icons.wifi_off,
          text: l10n.catalogSearchOffline,
          action: TextButton(
            key: const Key('catalog-retry'),
            onPressed: ref.read(catalogSearchProvider.notifier).reset,
            child: Text(l10n.catalogRetry),
          ),
        );
      case CatalogSearchStatus.loaded:
        return _results(l10n, state.results);
    }
  }

  Widget _results(AppLocalizations l10n, List<SearchResult> results) {
    if (results.isEmpty) {
      return StatusMessage(
        key: const Key('catalog-empty'),
        icon: Icons.search_off,
        text: l10n.catalogSearchEmpty,
      );
    }
    final market = ref.watch(catalogOwnMarketProvider);
    final divider = Divider(
      height: PillPalSizes.hairline,
      thickness: PillPalSizes.hairline,
      color: context.palette.border,
    );
    return PillPalCard(
      padding: EdgeInsets.zero,
      child: ListView.separated(
        key: const Key('catalog-results'),
        shrinkWrap: true,
        itemCount: results.length,
        separatorBuilder: (context, index) => divider,
        itemBuilder: (context, index) {
          final result = results[index];
          return CatalogResultTile(
            result: result,
            foreign: widget.kind == CatalogSearchKind.product &&
                result.market != market,
            onTap: () => Navigator.of(context).pop(result),
          );
        },
      ),
    );
  }
}
