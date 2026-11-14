import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/links/invite_link.dart';

// Synthetic hosts and token (the build's placeholder hosts, never real ones).
const String _token = 'abcdefghijklmnopqrstuvwxyz0123456789_-ABCDEF';
final LinkConfig _ru = LinkConfig.parse(
  LinkConfig.placeholderHosts,
  region: 'ru',
);

InviteLinkResult _parse(String input, {LinkConfig? config}) =>
    parseInviteLink(input, config ?? _ru);

void main() {
  group('accepted links', () {
    test('https://{host}/i#token of this region', () {
      final result = _parse('https://links-ru.pillpal.invalid/i#$_token');
      expect(result.token, _token);
      expect(result.problem, isNull);
    });

    test('a trailing slash, a default port and upper case host', () {
      expect(
          _parse('https://links-ru.pillpal.invalid/i/#$_token').token, _token);
      expect(
        _parse('https://links-ru.pillpal.invalid:443/i#$_token').token,
        _token,
      );
      expect(
          _parse('https://LINKS-RU.pillpal.invalid/i#$_token').token, _token);
    });

    test('the link inside a shared message', () {
      final result = _parse(
        'Join me on PillPal: https://links-ru.pillpal.invalid/i#$_token\nThanks',
      );
      expect(result.token, _token);
    });

    test('the EU build accepts the EU host', () {
      final eu = LinkConfig.parse(LinkConfig.placeholderHosts, region: 'eu');
      expect(
        _parse('https://links-eu.pillpal.invalid/i#$_token', config: eu).token,
        _token,
      );
    });
  });

  group('refused links', () {
    test('the other region cannot work in this build', () {
      final result = _parse('https://links-eu.pillpal.invalid/i#$_token');
      expect(result.token, isNull);
      expect(result.problem, InviteLinkProblem.otherRegion);
    });

    test('an unknown host is not trusted', () {
      expect(
        _parse('https://evil.example/i#$_token').problem,
        InviteLinkProblem.unknownHost,
      );
      // A look-alike of a known host.
      expect(
        _parse('https://links-ru.pillpal.invalid.evil.example/i#$_token')
            .problem,
        InviteLinkProblem.unknownHost,
      );
    });

    test('only https counts: http and custom schemes are malformed', () {
      for (final link in [
        'http://links-ru.pillpal.invalid/i#$_token',
        'pillpal://links-ru.pillpal.invalid/i#$_token',
        'ftp://links-ru.pillpal.invalid/i#$_token',
      ]) {
        expect(_parse(link).problem, InviteLinkProblem.malformed, reason: link);
      }
    });

    test('the token must be in the fragment, never in the query or path', () {
      for (final link in [
        'https://links-ru.pillpal.invalid/i?t=$_token',
        'https://links-ru.pillpal.invalid/i/$_token',
        'https://links-ru.pillpal.invalid/i?x=1#$_token',
        'https://links-ru.pillpal.invalid/i',
        'https://links-ru.pillpal.invalid/i#',
      ]) {
        expect(_parse(link).problem, InviteLinkProblem.malformed, reason: link);
      }
    });

    test('other paths, ports, credentials and short tokens', () {
      for (final link in [
        'https://links-ru.pillpal.invalid/other#$_token',
        'https://links-ru.pillpal.invalid:8443/i#$_token',
        'https://user:pw@links-ru.pillpal.invalid/i#$_token',
        'https://links-ru.pillpal.invalid/i#short',
        'https://links-ru.pillpal.invalid/i#${'a' * 300}',
        'https://links-ru.pillpal.invalid/i#abc def ghijklmnopqrstuvwxyz',
      ]) {
        expect(_parse(link).problem, InviteLinkProblem.malformed, reason: link);
      }
    });

    test('text that is not a link', () {
      for (final text in ['', '   ', 'hello', _token, 'https://']) {
        expect(_parse(text).token, isNull, reason: text);
      }
    });
  });

  group('look-alike links (scanned QR codes)', () {
    test('our host as user info of another host is that other host', () {
      final result =
          _parse('https://links-ru.pillpal.invalid@evil.example/i#$_token');
      expect(result.token, isNull);
      expect(result.problem, InviteLinkProblem.unknownHost);
    });

    test('user info before our host is refused', () {
      final result = _parse('https://user@links-ru.pillpal.invalid/i#$_token');
      expect(result.token, isNull);
      expect(result.problem, InviteLinkProblem.malformed);
    });

    test('a homoglyph host (Cyrillic р) is not ours', () {
      final result = _parse('https://links-ru.pillрal.invalid/i#$_token');
      expect(result.token, isNull);
      expect(result.problem, InviteLinkProblem.unknownHost);
    });

    test('a trailing dot makes another host', () {
      final result = _parse('https://links-ru.pillpal.invalid./i#$_token');
      expect(result.token, isNull);
      expect(result.problem, InviteLinkProblem.unknownHost);
    });

    test('a second # in the fragment is no token', () {
      final result = _parse('https://links-ru.pillpal.invalid/i#$_token#x');
      expect(result.token, isNull);
      expect(result.problem, InviteLinkProblem.malformed);
    });
  });

  group('canonical invite link', () {
    test('is rebuilt from the token and the region host only', () {
      expect(
        canonicalInviteLink(_token, _ru),
        'https://links-ru.pillpal.invalid/i#$_token',
      );
      // Whatever the server's spelling, the shared link is the same.
      final result = _parse('https://LINKS-RU.pillpal.invalid:443/i/#$_token');
      expect(
        canonicalInviteLink(result.token!, _ru),
        'https://links-ru.pillpal.invalid/i#$_token',
      );
    });

    test('a build without a host of its region has none', () {
      final none =
          LinkConfig.parse('eu=links-eu.pillpal.invalid', region: 'ru');
      expect(canonicalInviteLink(_token, none), isNull);
    });
  });

  test('the token never appears in toString', () {
    final result = _parse('https://links-ru.pillpal.invalid/i#$_token');
    expect(result.toString(), isNot(contains(_token)));
  });

  group('LinkConfig', () {
    test('parses "region=host" pairs and ignores junk', () {
      final config = LinkConfig.parse(
        ' ru = A.example , eu=b.example,junk,=x,y=,a=b=c',
        region: 'eu',
      );
      expect(config.hosts, {'ru': 'a.example', 'eu': 'b.example'});
      expect(config.regionOfHost('B.EXAMPLE'), 'eu');
      expect(config.regionOfHost('c.example'), isNull);
    });
  });
}
