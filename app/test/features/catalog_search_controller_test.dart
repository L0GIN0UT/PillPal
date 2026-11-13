import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/features/catalog/catalog_search_controller.dart';

import '../data/catalog_fixtures.dart';
import 'catalog_ui_env.dart';

// One search sheet's state: a late answer to an earlier request never
// overwrites a newer state, nothing unexpected leaves a stuck spinner, and
// typing searches only after the debounce pause (ADR 0015 §3). The typing
// tests run in `testWidgets` for its fake clock.

class _Rig {
  _Rig(Future<http.Response> Function(http.Request request) handler) {
    container = ProviderContainer(
      overrides: [
        catalogApiProvider.overrideWithValue(
          catalogApi(
            MockClient((request) {
              requests.add(request);
              return handler(request);
            }),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.listen(catalogSearchProvider, (previous, next) {});
  }

  late final ProviderContainer container;

  /// Every request the catalog saw.
  final List<http.Request> requests = [];

  CatalogSearchState get state => container.read(catalogSearchProvider);

  Future<void> search(String text) {
    return container
        .read(catalogSearchProvider.notifier)
        .search(text, lang: 'en');
  }

  void type(String text) {
    container.read(catalogSearchProvider.notifier).typed(text, lang: 'en');
  }

  /// The search texts the catalog received, in order.
  List<String> get queries => [
        for (final request in requests)
          (jsonDecode(request.body) as Map<String, Object?>)['q']! as String,
      ];
}

const Duration _justBefore = Duration(milliseconds: 1);

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

  group('typing', () {
    testWidgets('searches once after the pause', (tester) async {
      final rig = _Rig(
        (request) async => _answer([searchResultJson(id: productA)]),
      );

      rig.type('sy');
      await tester.pump(CatalogPolicy.searchDebounce - _justBefore);
      expect(rig.requests, isEmpty);
      await tester.pump(_justBefore);
      await tester.pump();

      expect(rig.queries, ['sy']);
      expect(rig.state.status, CatalogSearchStatus.loaded);
      await tester.pump(CatalogPolicy.searchDebounce * 2);
      expect(rig.requests, hasLength(1), reason: 'the pause fires once');
    });

    testWidgets('every keystroke restarts the pause', (tester) async {
      final rig = _Rig((request) async => _answer([]));

      rig.type('sy');
      await tester.pump(CatalogPolicy.searchDebounce - _justBefore);
      rig.type('syn');
      await tester.pump(CatalogPolicy.searchDebounce - _justBefore);
      rig.type('synt');
      await tester.pump(CatalogPolicy.searchDebounce - _justBefore);
      expect(rig.requests, isEmpty);
      await tester.pump(_justBefore);
      await tester.pump();

      expect(rig.queries, ['synt']);
    });

    testWidgets('a text shorter than the minimum is never sent',
        (tester) async {
      final rig = _Rig((request) async => _answer([]));

      rig.type(' s ');
      await tester.pump(CatalogPolicy.searchDebounce * 2);

      expect(rig.requests, isEmpty);
      expect(rig.state.status, CatalogSearchStatus.idle);
    });

    testWidgets('shortening the text cancels the pending search',
        (tester) async {
      final rig = _Rig((request) async => _answer([]));

      rig.type('sy');
      await tester.pump(CatalogPolicy.searchDebounce - _justBefore);
      rig.type('s');
      await tester.pump(CatalogPolicy.searchDebounce * 2);

      expect(rig.requests, isEmpty);
      expect(rig.state.status, CatalogSearchStatus.idle);
    });

    testWidgets('shortening the text drops the answer still on its way',
        (tester) async {
      final pending = Completer<http.Response>();
      final rig = _Rig((request) => pending.future);

      rig.type('sy');
      await tester.pump(CatalogPolicy.searchDebounce);
      expect(rig.state.status, CatalogSearchStatus.loading);
      rig.type('');
      pending.complete(_answer([searchResultJson(id: productA)]));
      await tester.pump();

      expect(rig.state.status, CatalogSearchStatus.idle);
    });

    testWidgets('a submit searches at once and cancels the pause',
        (tester) async {
      final rig = _Rig((request) async => _answer([]));

      rig.type('syn');
      await rig.search('syn');
      expect(rig.queries, ['syn']);
      await tester.pump(CatalogPolicy.searchDebounce * 2);

      expect(rig.queries, ['syn'], reason: 'the pending pause was cancelled');
    });

    testWidgets('a retry cancels the pending pause', (tester) async {
      final rig = _Rig((request) async => _answer([]));

      rig.type('syn');
      rig.container.read(catalogSearchProvider.notifier).reset();
      await tester.pump(CatalogPolicy.searchDebounce * 2);

      expect(rig.requests, isEmpty);
      expect(rig.state.status, CatalogSearchStatus.idle);
    });

    testWidgets('closing the sheet cancels the pending pause', (tester) async {
      final rig = _Rig((request) async => _answer([]));

      rig.type('syn');
      rig.container.dispose();
      await tester.pump(CatalogPolicy.searchDebounce * 2);

      expect(rig.requests, isEmpty);
    });

    testWidgets('going offline cancels the pause typed meanwhile',
        (tester) async {
      final pending = Completer<http.Response>();
      final rig = _Rig((request) => pending.future);

      rig.type('sy');
      await tester.pump(CatalogPolicy.searchDebounce);
      rig.type('syn');
      pending.completeError(http.ClientException('offline'));
      await tester.pump();
      await tester.pump(CatalogPolicy.searchDebounce * 2);

      expect(rig.state.status, CatalogSearchStatus.offline);
      expect(rig.requests, hasLength(1));
    });

    testWidgets('the earlier results stay while the next ones load',
        (tester) async {
      final second = Completer<http.Response>();
      final answers = [
        Future.value(_answer([searchResultJson(id: productA)])),
        second.future,
      ];
      final rig = _Rig((request) => answers.removeAt(0));

      rig.type('sy');
      await tester.pump(CatalogPolicy.searchDebounce);
      rig.type('syn');
      await tester.pump(CatalogPolicy.searchDebounce);

      expect(rig.state.status, CatalogSearchStatus.loading);
      expect(rig.state.results.single.id, productA);
      second.complete(_answer([searchResultJson(id: productB)]));
      await tester.pump();
      expect(rig.state.results.single.id, productB);
    });

    testWidgets('the same query is not sent twice in a row', (tester) async {
      final rig = _Rig((request) async => _answer([]));

      rig.type('syn');
      await tester.pump(CatalogPolicy.searchDebounce);
      await rig.search('syn');
      rig.type('syn ');
      await tester.pump(CatalogPolicy.searchDebounce * 2);

      expect(rig.queries, ['syn']);
      expect(rig.state.status, CatalogSearchStatus.loaded);
    });
  });
}
