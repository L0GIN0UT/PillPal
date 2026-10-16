import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

// "Аптеки рядом" (TZ §2.4): a deep link into the device's maps app with a
// pharmacy search. The app has no map of its own and asks for no location
// permission: the maps app searches around the user itself.

/// Opens URLs in other apps; [UrlLauncherOpener] in the app, a fake in tests.
abstract interface class UrlOpener {
  /// Whether an installed app handles [uri] (iOS: the scheme must be listed
  /// in `LSApplicationQueriesSchemes`).
  Future<bool> canOpen(Uri uri);

  /// Opens [uri] outside the app; false when nothing handled it.
  Future<bool> open(Uri uri);
}

/// [UrlOpener] over `url_launcher`.
class UrlLauncherOpener implements UrlOpener {
  /// Creates the opener.
  const UrlLauncherOpener();

  @override
  Future<bool> canOpen(Uri uri) async {
    try {
      return await canLaunchUrl(uri);
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> open(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      // No app for the scheme (e.g. no maps app for `geo:`): the caller tries
      // the next candidate. Nothing is logged.
      return false;
    }
  }
}

/// Yandex Maps app scheme (iOS check before linking into it).
final Uri yandexMapsProbe = Uri.parse('yandexmaps://');

/// Opens a pharmacy search in the maps app of the device.
class PharmacySearch {
  /// Creates the search for [platform] in data region [region] (`ru`/`eu`).
  const PharmacySearch({
    required UrlOpener opener,
    required TargetPlatform platform,
    required String region,
  })  : _opener = opener,
        _platform = platform,
        _region = region;

  final UrlOpener _opener;
  final TargetPlatform _platform;
  final String _region;

  bool get _russian => _region == 'ru';

  /// Searches for [query] ("аптека" / "pharmacy"); false when no candidate
  /// could be opened.
  Future<bool> open(String query) async {
    for (final uri in await candidates(query)) {
      if (await _opener.open(uri)) {
        return true;
      }
    }
    return false;
  }

  /// The links tried in order: Android's `geo:` intent (the user's default
  /// maps app); on iOS Yandex Maps when installed in the RU build, else
  /// Apple Maps; finally the web maps of the region.
  Future<List<Uri>> candidates(String query) async {
    final text = Uri.encodeComponent(query);
    final web = _russian
        ? Uri.parse('https://yandex.ru/maps/?text=$text')
        : Uri.parse('https://www.google.com/maps/search/?api=1&query=$text');
    switch (_platform) {
      case TargetPlatform.android:
        return [Uri.parse('geo:0,0?q=$text'), web];
      case TargetPlatform.iOS:
        final yandex = _russian && await _opener.canOpen(yandexMapsProbe);
        return [
          if (yandex) Uri.parse('yandexmaps://maps.yandex.ru/?text=$text'),
          Uri.parse('maps://?q=$text'),
          web,
        ];
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
      case TargetPlatform.windows:
        return [web];
    }
  }
}
