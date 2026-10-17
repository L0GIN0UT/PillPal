import '../data/config.dart';

/// Why a link or pasted text is not an invite of this region.
enum InviteLinkProblem {
  /// Not `https://{host}/i#<token>`.
  malformed,

  /// A host this app does not know (any other site).
  unknownHost,

  /// The link belongs to the other data region (TZ §1): it cannot work here.
  otherRegion,
}

/// The outcome of [parseInviteLink]: a [token] or a [problem].
///
/// The token is a bearer capability: [toString] never shows it.
class InviteLinkResult {
  const InviteLinkResult._({this.token, this.problem});

  /// An accepted link.
  const InviteLinkResult.ok(String token) : this._(token: token);

  /// A refused link.
  const InviteLinkResult.rejected(InviteLinkProblem problem)
      : this._(problem: problem);

  /// The invite token of an accepted link.
  final String? token;

  /// Why the link was refused; null for an accepted link.
  final InviteLinkProblem? problem;

  @override
  String toString() =>
      token == null ? 'InviteLink($problem)' : 'InviteLink(ok)';
}

final RegExp _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{20,256}$');

/// The path of invite links (`GET /i` on the backend).
const String inviteLinkPath = '/i';

/// Parses an invite link: `https://{link_host}/i#<token>` of this build's
/// region (docs/adr/0009-invite-links.md §1).
///
/// [input] may be a whole shared message: the first word that holds a
/// `://` is taken. Only https counts (no custom scheme exists), the host
/// must be a known link host of the region this build serves, and the token
/// must be in the fragment, which no server or proxy ever sees. Nothing is
/// requested here: the caller still asks the invitee to confirm.
InviteLinkResult parseInviteLink(String input, LinkConfig config) {
  const malformed = InviteLinkResult.rejected(InviteLinkProblem.malformed);
  final words = input.trim().split(RegExp(r'\s+'));
  final candidate = words.firstWhere(
    (word) => word.contains('://'),
    orElse: () => input.trim(),
  );
  final Uri uri;
  try {
    uri = Uri.parse(candidate);
  } on FormatException {
    return malformed;
  }
  if (uri.scheme != 'https' || uri.host.isEmpty) {
    return malformed;
  }
  final region = config.regionOfHost(uri.host);
  if (region == null) {
    return const InviteLinkResult.rejected(InviteLinkProblem.unknownHost);
  }
  if (region != config.region) {
    return const InviteLinkResult.rejected(InviteLinkProblem.otherRegion);
  }
  final plainHttps = uri.userInfo.isEmpty &&
      (!uri.hasPort || uri.port == 443) &&
      !uri.hasQuery &&
      (uri.path == inviteLinkPath || uri.path == '$inviteLinkPath/');
  if (!plainHttps || !_tokenPattern.hasMatch(uri.fragment)) {
    return malformed;
  }
  return InviteLinkResult.ok(uri.fragment);
}
