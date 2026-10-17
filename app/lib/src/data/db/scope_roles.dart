/// Roles of the signed-in account on a profile (`ScopeOut.role`, ADR 0005).
abstract final class ScopeRole {
  /// The profile's owner (`profiles.owner_user_id`).
  static const String owner = 'owner';

  /// A co-guardian of a managed profile: full access.
  static const String guardian = 'guardian';

  /// "View and edit": projected data, edits `shared` medications only.
  static const String editor = 'editor';

  /// "View": projected data, read-only.
  static const String viewer = 'viewer';

  /// Whether the role sees entities unchanged (no privacy projection).
  static bool hasFullAccess(String role) => role == owner || role == guardian;

  /// Whether the server projects entities for the role (ADR 0006 §3).
  static bool isProjected(String role) => role == editor || role == viewer;

  /// Whether the scope is not the account's own (any role but owner).
  /// Foreign scopes are never read or reconciled over REST and never keep
  /// tombstones (ADR 0006 §7).
  static bool isForeign(String role) => role != owner;

  /// Whether a scope of [kind] and [role] is the account's own `self`
  /// profile: the only one whose `local` medications follow the device zone
  /// (the phone is where that person is) and that always reminds. Every
  /// other scope keeps its profile's zone (D4, ADR 0007 §5).
  static bool isOwnSelf(String kind, String role) =>
      kind == 'self' && role == owner;

  /// Whether the role may fire reminders (never relatives with a view).
  static bool mayRemind(String role) => hasFullAccess(role);

  /// Whether this device reminds for a scope of [role] given its explicit
  /// per-device switch ([explicit], null when the device has none): an owned
  /// profile reminds unless switched off, a co-guardian's only when
  /// switched on, everyone else never (ADR 0005 §2).
  static bool remindsByDefault(String role, bool? explicit) {
    if (role == owner) {
      return explicit ?? true;
    }
    return role == guardian && (explicit ?? false);
  }
}
