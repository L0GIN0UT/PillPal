import 'json.dart';

// Wire forms of creating an invite and of its state for the creator
// (backend/app/schemas/relatives.py, docs/adr/0020). The token lives only
// inside `InviteCreated.url`: no `toString` here prints it.

/// A freshly created invite (`InviteCreated`). The link holds the token and
/// is shown once.
class InviteCreated {
  /// Creates an invite.
  const InviteCreated({
    required this.id,
    required this.role,
    required this.createdAt,
    required this.expiresAt,
    required this.url,
  });

  /// Parses `InviteCreated`.
  factory InviteCreated.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return InviteCreated(
      id: reader.string('id'),
      role: reader.string('role'),
      createdAt: reader.instant('created_at'),
      expiresAt: reader.instant('expires_at'),
      url: reader.string('url'),
    );
  }

  /// Keys read from `InviteCreated`.
  static const Set<String> readKeys = {
    'id',
    'role',
    'created_at',
    'expires_at',
    'url',
  };

  /// Invite id (the client's UUID).
  final String id;

  /// `viewer`, `editor` or `guardian`.
  final String role;

  /// Server time of creation: with [expiresAt] it gives the lifetime without
  /// the phone's clock (docs/adr/0020 §1).
  final DateTime createdAt;

  /// When the invite lapses.
  final DateTime expiresAt;

  /// `https://{link_host}/i#<token>`: a bearer capability.
  final String url;

  /// How long the invite lives, by the server's own clock.
  Duration get lifetime => expiresAt.difference(createdAt);

  @override
  // The link holds the token: never in a log or an error.
  String toString() => 'InviteCreated($id, $role)';
}

/// The states of an invite in `GET /v1/invites/{id}` (docs/adr/0020 §2).
abstract final class InviteState {
  /// Waiting to be accepted.
  static const String open = 'open';

  /// Accepted: the relative is linked.
  static const String consumed = 'consumed';

  /// Lapsed unused.
  static const String expired = 'expired';

  /// Revoked, or its profile is gone.
  static const String revoked = 'revoked';

  /// Every state.
  static const Set<String> all = {open, consumed, expired, revoked};
}

/// The state of an invite for its creator (`InviteStatus`): no token, no
/// link, nothing about who accepted.
class InviteStatus {
  /// Creates a status.
  const InviteStatus({
    required this.id,
    required this.role,
    required this.state,
    required this.createdAt,
    required this.expiresAt,
  });

  /// Parses `InviteStatus`.
  factory InviteStatus.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return InviteStatus(
      id: reader.string('id'),
      role: reader.string('role'),
      state: reader.string('state'),
      createdAt: reader.instant('created_at'),
      expiresAt: reader.instant('expires_at'),
    );
  }

  /// Keys read from `InviteStatus`.
  static const Set<String> readKeys = {
    'id',
    'role',
    'state',
    'created_at',
    'expires_at',
  };

  /// Invite id.
  final String id;

  /// `viewer`, `editor` or `guardian`.
  final String role;

  /// One of [InviteState.all].
  final String state;

  /// Server time of creation.
  final DateTime createdAt;

  /// When the invite lapses.
  final DateTime expiresAt;
}
