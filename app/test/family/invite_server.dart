import 'dart:convert';

import 'package:http/http.dart' as http;

import 'family_fixtures.dart';

// The invite endpoints of the backend for widget tests of the QR panel
// (docs/adr/0020). Data is synthetic; the token is a bearer secret in real
// life and is only ever put into the QR code and the share sheet.

/// A synthetic token of an invite link.
const String inviteToken = 'abcdefghijklmnopqrstuvwxyz012345';

/// An invite link of this build's region (RU in tests).
const String inviteUrl = 'https://links-ru.pillpal.invalid/i#$inviteToken';

/// A link of a host this app does not serve.
const String foreignInviteUrl = 'https://evil.example/i#$inviteToken';

/// How long a code lives on the fake server (the backend default).
const Duration inviteLifetime = Duration(minutes: 15);

/// Server time of creation. Far from the test clock on purpose: the app must
/// count down from the server's own pair, not from the phone's clock.
final DateTime inviteCreatedAt = DateTime.utc(2026, 10, 16, 5, 3);

/// Answers the invite endpoints and logs every request.
class FakeInviteServer {
  /// Every request as `METHOD /path`.
  final List<String> log = [];

  /// The JSON bodies of the `POST` creating invites, in order.
  final List<Map<String, Object?>> created = [];

  /// The link the server puts into new invites.
  String url = inviteUrl;

  /// What `GET /v1/invites/{id}` says.
  String state = 'open';

  /// The owner's outgoing grants in `GET /v1/grants`.
  List<Map<String, Object?>> outgoing = [];

  /// An answer to `POST .../invites` instead of a new invite (an error).
  http.Response? createAnswer;

  /// How many next `POST .../invites` answer 409 `already_exists`, as for
  /// the replay of a create whose response was lost.
  int replays = 0;

  /// Ids of revoked invites, in order.
  Iterable<String> get revoked => log
      .where((line) => line.startsWith('DELETE ') && line.contains('/invites/'))
      .map((line) => line.split('/').last);

  /// Ids of the invites whose state was asked, in order.
  Iterable<String> get polled => log
      .where((line) => line.startsWith('GET /v1/invites/'))
      .map((line) => line.split('/').last);

  /// The handler for `TestHarness`.
  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    log.add('${request.method} $path');
    if (request.method == 'POST' && path.endsWith('/invites')) {
      final body = jsonDecode(request.body) as Map<String, Object?>;
      created.add(body);
      if (replays > 0) {
        replays--;
        return errorResponse(409, 'already_exists');
      }
      return createAnswer ??
          jsonResponse(
            {
              'id': body['id'],
              'role': body['role'],
              'created_at': inviteCreatedAt.toIso8601String(),
              'expires_at':
                  inviteCreatedAt.add(inviteLifetime).toIso8601String(),
              'url': url,
            },
            201,
          );
    }
    if (request.method == 'DELETE' && path.contains('/invites/')) {
      return http.Response('', 204);
    }
    if (request.method == 'GET' && path.startsWith('/v1/invites/')) {
      return jsonResponse({
        'id': path.split('/').last,
        'role': 'viewer',
        'state': state,
        'created_at': inviteCreatedAt.toIso8601String(),
        'expires_at': inviteCreatedAt.add(inviteLifetime).toIso8601String(),
      });
    }
    if (path == '/v1/grants') {
      return jsonResponse(grantsJson(outgoing: outgoing));
    }
    return http.Response('', 503);
  }
}
