import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/features/catalog/catalog_search_controller.dart';

import '../data/catalog_fixtures.dart';
import 'catalog_ui_env.dart';

// One search sheet's state: a late answer to an earlier request never
// overwrites a newer state, and nothing unexpected leaves a stuck spinner.

class _Rig {
  _Rig(Future<http.Response> Function(http.Request request) handler) {
    container = ProviderContainer(
      overrides: [
        catalogApiProvider.overrideWithValue(catalogApi(MockClient(handler))),
      ],
    );
    addTearDown(container.dispose);
    container.listen(catalogSearchProvider, (previous, next) {});
  }

  late final ProviderContainer container;

  CatalogSearchState get state => container.read(catalogSearchProvider);

  Future<void> search(String text) {
    return container
        .read(catalogSearchProvider.notifier)
        .search(text, lang: 'en');
  }
}

http.Response _answer(List<Map<String, Object?>> results) =>
    jsonResponse({'mode': 'text', 'results': results});

void main() {
  test('a stale answer does not overwrite a too-short submit', () async {
    final pending = Completer<http.Response>();
    final rig = _Rig((request) => pending.future);

    final first = rig.search('abc');
    expect(rig.state.status, CatalogSearchStatus.loading);
    await rig.search('a');
    expect(rig.state.status, CatalogSearchStatus.tooShort);

    pending.complete(_answer([searchResultJson(id: productA)]));
    await first;

    expect(rig.state.status, CatalogSearchStatus.tooShort);
  });

  test('a stale answer does not overwrite a newer search', () async {
    final first = Completer<http.Response>();
    final second = Completer<http.Response>();
    final queue = [first, second];
    final rig = _Rig((request) => queue.removeAt(0).future);

    final one = rig.search('first');
    final two = rig.search('second');
    second.complete(_answer([searchResultJson(id: productB)]));
    await two;
    first.complete(_answer([searchResultJson(id: productA)]));
    await one;

    expect(rig.state.results.single.id, productB);
  });

  test('a stale answer does not overwrite a reset (retry)', () async {
    final pending = Completer<http.Response>();
    final rig = _Rig((request) => pending.future);

    final first = rig.search('abc');
    rig.container.read(catalogSearchProvider.notifier).reset();
    pending.complete(_answer([searchResultJson(id: productA)]));
    await first;

    expect(rig.state.status, CatalogSearchStatus.idle);
  });

  test('an unexpected error is a failed search, not a stuck spinner', () async {
    final rig = _Rig((request) => throw StateError('boom'));

    await rig.search('abc');

    expect(rig.state.status, CatalogSearchStatus.failed);
  });

  test('a network error is offline', () async {
    final rig = _Rig((request) => throw http.ClientException('offline'));

    await rig.search('abc');

    expect(rig.state.status, CatalogSearchStatus.offline);
  });

  test('own-market results come first', () async {
    final rig = _Rig(
      (request) async => _answer([
        searchResultJson(id: 'us-1', market: 'us'),
        searchResultJson(id: 'ru-1'),
      ]),
    );

    await rig.search('abc');

    expect(rig.state.results.map((r) => r.id), ['ru-1', 'us-1']);
  });
}
