import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/pharmacies/pharmacy_search.dart';

import 'fake_url_opener.dart';

PharmacySearch _search(
  FakeUrlOpener opener,
  TargetPlatform platform, {
  String region = 'ru',
}) =>
    PharmacySearch(opener: opener, platform: platform, region: region);

void main() {
  test('Android opens the geo: search of the default maps app', () async {
    final opener = FakeUrlOpener(handled: {'geo'});
    expect(await _search(opener, TargetPlatform.android).open('аптека'), true);
    expect(opener.opened.single.toString(),
        'geo:0,0?q=%D0%B0%D0%BF%D1%82%D0%B5%D0%BA%D0%B0');
  });

  test('Android without a maps app falls back to the web maps of the region',
      () async {
    final ru = FakeUrlOpener(handled: {'https'});
    expect(await _search(ru, TargetPlatform.android).open('аптека'), isTrue);
    expect(ru.opened.map((uri) => uri.scheme), ['geo', 'https']);
    expect(ru.opened.last.host, 'yandex.ru');
    expect(ru.opened.last.queryParameters['text'], 'аптека');

    final eu = FakeUrlOpener(handled: {'https'});
    await _search(eu, TargetPlatform.android, region: 'eu').open('pharmacy');
    expect(eu.opened.last.host, 'www.google.com');
    expect(eu.opened.last.queryParameters['query'], 'pharmacy');
  });

  test('iOS in the RU build prefers Yandex Maps when installed', () async {
    final opener = FakeUrlOpener(
      handled: {'yandexmaps', 'maps', 'https'},
      installed: {'yandexmaps'},
    );
    await _search(opener, TargetPlatform.iOS).open('аптека');
    final uri = opener.opened.single;
    expect(uri.scheme, 'yandexmaps');
    expect(uri.host, 'maps.yandex.ru');
    expect(uri.queryParameters['text'], 'аптека');
  });

  test('iOS uses Apple Maps without Yandex Maps or outside RU', () async {
    final missing = FakeUrlOpener(handled: {'maps', 'https'});
    await _search(missing, TargetPlatform.iOS).open('аптека');
    expect(missing.opened.single.scheme, 'maps');
    expect(missing.opened.single.queryParameters['q'], 'аптека');

    final eu = FakeUrlOpener(
      handled: {'yandexmaps', 'maps', 'https'},
      installed: {'yandexmaps'},
    );
    await _search(eu, TargetPlatform.iOS, region: 'eu').open('pharmacy');
    expect(eu.opened.single.scheme, 'maps');
  });

  test('nothing opened reports failure after trying every candidate', () async {
    final opener = FakeUrlOpener();
    expect(await _search(opener, TargetPlatform.iOS).open('аптека'), isFalse);
    expect(opener.opened.map((uri) => uri.scheme), ['maps', 'https']);
  });
}
