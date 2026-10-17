import 'json.dart';

// Wire forms of the relatives API (backend/app/schemas/relatives.py,
// docs/adr/0005 and 0009). Readers declare the keys they read so that the
// contract test can check them against spec/openapi.json. Invite tokens live
// only inside `InviteCreated.url` and the request bodies: no `toString` here
// prints them.

/// A freshly created invite (`InviteCreated`). The link holds the token and
/// is shown once.
class InviteCreated {
  /// Creates an invite.
  const InviteCreated({
    required this.id,
    required this.role,
    required this.expiresAt,
    required this.url,
  });

  /// Parses `InviteCreated`.
  factory InviteCreated.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return InviteCreated(
      id: reader.string('id'),
      role: reader.string('role'),
      expiresAt: reader.instant('expires_at'),
      url: reader.string('url'),
    );
  }

  /// Keys read from `InviteCreated`.
  static const Set<String> readKeys = {'id', 'role', 'expires_at', 'url'};

  /// Invite id (the client's UUID).
  final String id;

  /// `viewer`, `editor` or `guardian`.
  final String role;

  /// When the invite lapses.
  final DateTime expiresAt;

  /// `https://{link_host}/i#<token>`: a bearer capability.
  final String url;
}

/// An open invite of a profile (`InviteOut`); the token is never listed.
class InviteSummary {
  /// Creates a summary.
  const InviteSummary({
    required this.id,
    required this.role,
    required this.createdAt,
    required this.expiresAt,
  });

  /// Parses `InviteOut`.
  factory InviteSummary.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return InviteSummary(
      id: reader.string('id'),
      role: reader.string('role'),
      createdAt: reader.instant('created_at'),
      expiresAt: reader.instant('expires_at'),
    );
  }

  /// Keys read from `InviteOut`.
  static const Set<String> readKeys = {
    'id',
    'role',
    'created_at',
    'expires_at',
  };

  /// Invite id.
  final String id;

  /// Offered role.
  final String role;

  /// Creation instant.
  final DateTime createdAt;

  /// Expiry instant.
  final DateTime expiresAt;
}

/// What an invitee sees before confirming (`InvitePreview`).
class InvitePreview {
  /// Creates a preview.
  const InvitePreview({
    required this.inviterDisplayName,
    required this.profileDisplayName,
    required this.profileKind,
    required this.role,
    required this.expiresAt,
  });

  /// Parses `InvitePreview`.
  factory InvitePreview.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return InvitePreview(
      inviterDisplayName: reader.stringOrNull('inviter_display_name'),
      profileDisplayName: reader.string('profile_display_name'),
      profileKind: reader.string('profile_kind'),
      role: reader.string('role'),
      expiresAt: reader.instant('expires_at'),
    );
  }

  /// Keys read from `InvitePreview`.
  static const Set<String> readKeys = {
    'inviter_display_name',
    'profile_display_name',
    'profile_kind',
    'role',
    'expires_at',
  };

  /// The inviter's name, when they have one.
  final String? inviterDisplayName;

  /// Name of the profile the invite is for.
  final String profileDisplayName;

  /// `self` or `managed`.
  final String profileKind;

  /// Offered role.
  final String role;

  /// When the invite lapses.
  final DateTime expiresAt;
}

/// A grant on one of the account's own profiles (`OutgoingGrantOut`).
class OutgoingGrant {
  /// Creates a grant.
  const OutgoingGrant({
    required this.id,
    required this.profileId,
    required this.profileDisplayName,
    required this.profileKind,
    required this.role,
    required this.granteeDisplayName,
    required this.active,
    required this.disclosureVersion,
    required this.createdAt,
  });

  /// Parses `OutgoingGrantOut`.
  factory OutgoingGrant.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return OutgoingGrant(
      id: reader.string('id'),
      profileId: reader.string('profile_id'),
      profileDisplayName: reader.string('profile_display_name'),
      profileKind: reader.string('profile_kind'),
      role: reader.string('role'),
      granteeDisplayName: reader.stringOrNull('grantee_display_name'),
      active: reader.boolean('active'),
      disclosureVersion: reader.integer('disclosure_version'),
      createdAt: reader.instant('created_at'),
    );
  }

  /// Keys read from `OutgoingGrantOut`.
  static const Set<String> readKeys = {
    'id',
    'profile_id',
    'profile_display_name',
    'profile_kind',
    'role',
    'grantee_display_name',
    'active',
    'disclosure_version',
    'created_at',
  };

  /// Grant id.
  final String id;

  /// The own profile it is on.
  final String profileId;

  /// That profile's name.
  final String profileDisplayName;

  /// `self` or `managed`.
  final String profileKind;

  /// `viewer`, `editor` or `guardian`.
  final String role;

  /// The relative's name, when they have one.
  final String? granteeDisplayName;

  /// False while the relative's account (or the owner's) is in its deletion
  /// grace period: no access, kept so that a restore brings it back.
  final bool active;

  /// Version of the disclosure screen the owner confirmed.
  final int disclosureVersion;

  /// When the relative accepted.
  final DateTime createdAt;
}

/// A grant of the account on someone else's profile (`IncomingGrantOut`).
class IncomingGrant {
  /// Creates a grant.
  const IncomingGrant({
    required this.id,
    required this.profileId,
    required this.profileDisplayName,
    required this.profileKind,
    required this.role,
    required this.ownerDisplayName,
    required this.notifyMissed,
    required this.createdAt,
  });

  /// Parses `IncomingGrantOut`.
  factory IncomingGrant.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return IncomingGrant(
      id: reader.string('id'),
      profileId: reader.string('profile_id'),
      profileDisplayName: reader.string('profile_display_name'),
      profileKind: reader.string('profile_kind'),
      role: reader.string('role'),
      ownerDisplayName: reader.stringOrNull('owner_display_name'),
      notifyMissed: reader.boolean('notify_missed'),
      createdAt: reader.instant('created_at'),
    );
  }

  /// Keys read from `IncomingGrantOut`.
  static const Set<String> readKeys = {
    'id',
    'profile_id',
    'profile_display_name',
    'profile_kind',
    'role',
    'owner_display_name',
    'notify_missed',
    'created_at',
  };

  /// Grant id.
  final String id;

  /// The profile the account was granted access to.
  final String profileId;

  /// That profile's name.
  final String profileDisplayName;

  /// `self` or `managed`.
  final String profileKind;

  /// `viewer`, `editor` or `guardian`.
  final String role;

  /// The owner's name, when they have one.
  final String? ownerDisplayName;

  /// Whether the account is alerted about missed doses.
  final bool notifyMissed;

  /// When the account accepted.
  final DateTime createdAt;
}

/// Both directions of `GET /v1/grants` (`GrantList`).
class GrantList {
  /// Creates a list.
  const GrantList({required this.outgoing, required this.incoming});

  /// Parses `GrantList`.
  factory GrantList.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return GrantList(
      outgoing: [
        for (final item in reader.list('outgoing'))
          OutgoingGrant.fromJson(asJsonMap(item, 'outgoing grant')),
      ],
      incoming: [
        for (final item in reader.list('incoming'))
          IncomingGrant.fromJson(asJsonMap(item, 'incoming grant')),
      ],
    );
  }

  /// Keys read from `GrantList`.
  static const Set<String> readKeys = {'outgoing', 'incoming'};

  /// Who sees my profiles.
  final List<OutgoingGrant> outgoing;

  /// Whose profiles I see.
  final List<IncomingGrant> incoming;
}

/// What to gate in the UI (`FeaturesOut`).
class AccountFeatures {
  /// Creates the features; the default has no limits.
  const AccountFeatures({
    this.softLimitsEnabled = false,
    this.relativesLimit,
    this.pdfReportsLimit,
  });

  /// Parses `FeaturesOut`.
  factory AccountFeatures.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return AccountFeatures(
      softLimitsEnabled: reader.boolean('soft_limits_enabled'),
      relativesLimit: reader.integerOrNull('relatives_limit'),
      pdfReportsLimit: reader.integerOrNull('pdf_reports_limit'),
    );
  }

  /// Keys read from `FeaturesOut`.
  static const Set<String> readKeys = {
    'soft_limits_enabled',
    'relatives_limit',
    'pdf_reports_limit',
  };

  /// Whether the soft limits are on at all.
  final bool softLimitsEnabled;

  /// Active relatives allowed on the account's profiles; null without limit.
  final int? relativesLimit;

  /// PDF reports allowed; null without limit.
  final int? pdfReportsLimit;

  /// Whether [activeRelatives] already fills the relatives limit.
  bool relativesLimitReached(int activeRelatives) {
    final limit = relativesLimit;
    return softLimitsEnabled && limit != null && activeRelatives >= limit;
  }
}

/// The `details` of `403 account_pending_deletion`: what restoring needs.
class PendingDeletion {
  /// Creates the details.
  const PendingDeletion({
    required this.restoreTicket,
    required this.eraseAfter,
  });

  /// Reads the envelope's `details`; null when they are not these.
  static PendingDeletion? fromDetails(Map<String, Object?>? details) {
    if (details == null) {
      return null;
    }
    final reader = JsonReader(details, readKeys);
    try {
      return PendingDeletion(
        restoreTicket: reader.string('restore_ticket'),
        eraseAfter: reader.instant('erase_after'),
      );
    } on FormatException {
      return null;
    }
  }

  /// Keys read from the error details.
  static const Set<String> readKeys = {'restore_ticket', 'erase_after'};

  /// Single-use bearer secret of the restore (10 minutes); never logged.
  final String restoreTicket;

  /// When the account is erased unless restored.
  final DateTime eraseAfter;
}

/// Request bodies of the relatives and deletion endpoints.
abstract final class RelativesBodies {
  /// `InviteCreate`.
  static JsonMap createInvite({
    required String id,
    required String role,
    required int disclosureVersion,
  }) =>
      {'id': id, 'role': role, 'disclosure_version': disclosureVersion};

  /// `InviteTokenRequest` (preview and accept).
  static JsonMap token(String token) => {'token': token};

  /// `GrantPatch` changing the role: exactly this one change plus the
  /// disclosure version, never mixed with `notify_missed`.
  static JsonMap changeRole(String role, int disclosureVersion) =>
      {'role': role, 'disclosure_version': disclosureVersion};

  /// `GrantPatch` changing the grantee's alert choice only.
  static JsonMap notifyMissed({required bool enabled}) =>
      {'notify_missed': enabled};

  /// `DeleteAccountRequest`.
  static JsonMap deleteAccount(String password) => {'password': password};
}
