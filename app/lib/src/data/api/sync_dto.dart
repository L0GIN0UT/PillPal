import 'json.dart';

/// Synced entity kinds (`SyncEntity`).
enum SyncEntity {
  /// A person whose medications are tracked.
  profile('profile'),

  /// A medication of a profile.
  medication('medication'),

  /// A schedule of a medication.
  schedule('schedule'),

  /// An append-only dose event.
  doseEvent('dose_event');

  const SyncEntity(this.wire);

  /// Wire name.
  final String wire;

  /// Parses a wire name.
  static SyncEntity fromWire(String value) => values.firstWhere(
        (entity) => entity.wire == value,
        orElse: () => throw FormatException('Unknown entity: $value'),
      );
}

/// Mutation kinds (`SyncOp`).
enum SyncOp {
  /// Create or replace with the full state.
  upsert('upsert'),

  /// Tombstone (final).
  delete('delete');

  const SyncOp(this.wire);

  /// Wire name.
  final String wire;

  /// Parses a wire name.
  static SyncOp fromWire(String value) => values.firstWhere(
        (op) => op.wire == value,
        orElse: () => throw FormatException('Unknown op: $value'),
      );
}

/// One pushed change (`Mutation`).
class Mutation {
  /// Creates a mutation.
  const Mutation({
    required this.entity,
    required this.op,
    required this.id,
    required this.data,
    required this.clientUpdatedAt,
  });

  /// Entity kind.
  final SyncEntity entity;

  /// Upsert or delete.
  final SyncOp op;

  /// Client-generated id.
  final String id;

  /// Full entity state for upserts (`*Data` schemas), null for deletes.
  final JsonMap? data;

  /// Last-write-wins key of this write.
  final DateTime clientUpdatedAt;

  /// Wire form.
  JsonMap toJson() => {
        'entity': entity.wire,
        'op': op.wire,
        'id': id,
        'data': data,
        'client_updated_at': instantToJson(clientUpdatedAt),
      };
}

/// Current server state of an entity (`EntityState`).
class EntityState {
  /// Creates a state.
  const EntityState({
    required this.op,
    required this.data,
    required this.clientUpdatedAt,
    required this.updatedByDevice,
    required this.deletedAt,
  });

  /// Parses `EntityState` (or the same fields of `Change`).
  factory EntityState.fromJson(JsonMap json) =>
      EntityState.read(JsonReader(json, readKeys));

  /// Reads the state fields through [reader].
  factory EntityState.read(JsonReader reader) {
    return EntityState(
      op: SyncOp.fromWire(reader.string('op')),
      data: reader.objectOrNull('data'),
      clientUpdatedAt: reader.instantOrNull('client_updated_at'),
      updatedByDevice: reader.stringOrNull('updated_by_device'),
      deletedAt: reader.instantOrNull('deleted_at'),
    );
  }

  /// Keys read from `EntityState`.
  static const Set<String> readKeys = {
    'op',
    'data',
    'client_updated_at',
    'updated_by_device',
    'deleted_at',
  };

  /// `delete` for tombstones.
  final SyncOp op;

  /// Current state (`*Out` schema); null for tombstones.
  final JsonMap? data;

  /// Conflict key; null for dose events.
  final DateTime? clientUpdatedAt;

  /// Conflict key tie-break; null for dose events.
  final String? updatedByDevice;

  /// When the entity was deleted, for tombstones.
  final DateTime? deletedAt;

  /// Whether this is a tombstone.
  bool get isDeleted => op == SyncOp.delete;
}

/// Outcome of one mutation (`MutationResult.status`).
enum MutationStatus {
  /// Stored, or an idempotent replay.
  applied('applied'),

  /// The server has a newer write or a tombstone; adopt `current`.
  ignoredStale('ignored_stale'),

  /// Invalid; see the code.
  rejected('rejected');

  const MutationStatus(this.wire);

  /// Wire name.
  final String wire;

  /// Parses a wire name.
  static MutationStatus fromWire(String value) => values.firstWhere(
        (status) => status.wire == value,
        orElse: () => throw FormatException('Unknown status: $value'),
      );
}

/// Result of one pushed mutation (`MutationResult`).
class MutationResult {
  /// Creates a result.
  const MutationResult({
    required this.entity,
    required this.id,
    required this.status,
    this.code,
    this.current,
  });

  /// Parses `MutationResult`.
  factory MutationResult.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    final current = reader.objectOrNull('current');
    return MutationResult(
      entity: SyncEntity.fromWire(reader.string('entity')),
      id: reader.string('id'),
      status: MutationStatus.fromWire(reader.string('status')),
      code: reader.stringOrNull('code'),
      current: current == null ? null : EntityState.fromJson(current),
    );
  }

  /// Keys read from `MutationResult`.
  static const Set<String> readKeys = {
    'entity',
    'id',
    'status',
    'code',
    'current',
  };

  /// Entity kind.
  final SyncEntity entity;

  /// Entity id.
  final String id;

  /// Outcome.
  final MutationStatus status;

  /// Error or detail code (`deleted`, `key_conflict`, `clock_skew`, ...).
  final String? code;

  /// Server state to adopt (ignored_stale and key_conflict).
  final EntityState? current;
}

/// One pulled change (`Change`).
class Change {
  /// Creates a change.
  const Change({
    required this.seq,
    required this.scope,
    required this.entity,
    required this.id,
    required this.state,
  });

  /// Parses `Change`.
  factory Change.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return Change(
      seq: reader.integer('seq'),
      scope: reader.string('scope'),
      entity: SyncEntity.fromWire(reader.string('entity')),
      id: reader.string('id'),
      state: EntityState.read(reader),
    );
  }

  /// Keys read from `Change`.
  static const Set<String> readKeys = {
    'seq',
    'scope',
    'entity',
    'id',
    ...EntityState.readKeys,
  };

  /// Journal position.
  final int seq;

  /// The profile (sync scope) the change belongs to.
  final String scope;

  /// Entity kind.
  final SyncEntity entity;

  /// Entity id.
  final String id;

  /// Current server state of the entity (projected for relatives).
  final EntityState state;
}

/// One scope the account can access (`ScopeOut`).
class PulledScope {
  /// Creates a scope.
  const PulledScope({
    required this.profileId,
    required this.role,
    required this.kind,
    required this.archived,
    required this.archivePurgeAfter,
    required this.ownerLastSeenAt,
    required this.cursor,
    required this.backfillUntil,
  });

  /// Parses `ScopeOut`.
  factory PulledScope.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return PulledScope(
      profileId: reader.string('profile_id'),
      role: reader.string('role'),
      kind: reader.string('kind'),
      archived: reader.boolean('archived'),
      archivePurgeAfter: reader.instantOrNull('archive_purge_after'),
      ownerLastSeenAt: reader.instantOrNull('owner_last_seen_at'),
      cursor: reader.integerOrNull('cursor'),
      backfillUntil: reader.integerOrNull('backfill_until'),
    );
  }

  /// Keys read from `ScopeOut`.
  static const Set<String> readKeys = {
    'profile_id',
    'role',
    'kind',
    'archived',
    'archive_purge_after',
    'owner_last_seen_at',
    'cursor',
    'backfill_until',
  };

  /// The profile.
  final String profileId;

  /// `owner`, `guardian`, `editor` or `viewer`.
  final String role;

  /// `self` or `managed`.
  final String kind;

  /// A read-only archive.
  final bool archived;

  /// When an archive is purged, once its owner is erased.
  final DateTime? archivePurgeAfter;

  /// When the owner's devices last synced (floored to the hour); only on
  /// other people's `self` profiles.
  final DateTime? ownerLastSeenAt;

  /// The scope's cursor after this page; null when it was not requested.
  final int? cursor;

  /// The unfinished backfill's target, to echo until the cursor reaches it.
  final int? backfillUntil;
}

/// One scoped pull page (`ScopedPullResponse`).
class ScopedPullPage {
  /// Creates a page.
  const ScopedPullPage({
    required this.scopes,
    required this.revoked,
    required this.changes,
    required this.hasMore,
  });

  /// Parses `ScopedPullResponse`.
  factory ScopedPullPage.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return ScopedPullPage(
      scopes: [
        for (final item in reader.list('scopes'))
          PulledScope.fromJson(asJsonMap(item, 'scope')),
      ],
      revoked: _strings(reader.list('revoked'), 'revoked'),
      changes: [
        for (final item in reader.list('changes'))
          Change.fromJson(asJsonMap(item, 'change')),
      ],
      hasMore: reader.boolean('has_more'),
    );
  }

  /// Keys read from `ScopedPullResponse`.
  static const Set<String> readKeys = {
    'scopes',
    'revoked',
    'changes',
    'has_more',
  };

  /// Every scope the account can access.
  final List<PulledScope> scopes;

  /// Requested scopes the account cannot access.
  final List<String> revoked;

  /// Changes of the requested scopes in journal order (parents first).
  final List<Change> changes;

  /// Whether another page follows for the same cursors.
  final bool hasMore;
}

List<String> _strings(List<Object?> items, String key) {
  return [
    for (final item in items)
      item is String
          ? item
          : throw FormatException('Expected a string in "$key"'),
  ];
}
