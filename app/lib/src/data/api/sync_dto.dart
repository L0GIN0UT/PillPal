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
    required this.entity,
    required this.id,
    required this.state,
  });

  /// Parses `Change`.
  factory Change.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return Change(
      seq: reader.integer('seq'),
      entity: SyncEntity.fromWire(reader.string('entity')),
      id: reader.string('id'),
      state: EntityState.read(reader),
    );
  }

  /// Keys read from `Change`.
  static const Set<String> readKeys = {
    'seq',
    'entity',
    'id',
    ...EntityState.readKeys,
  };

  /// Journal position.
  final int seq;

  /// Entity kind.
  final SyncEntity entity;

  /// Entity id.
  final String id;

  /// Current server state of the entity.
  final EntityState state;
}

/// One pull page (`PullResponse`).
class PullPage {
  /// Creates a page.
  const PullPage({
    required this.changes,
    required this.nextCursor,
    required this.hasMore,
  });

  /// Parses `PullResponse`.
  factory PullPage.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return PullPage(
      changes: [
        for (final item in reader.list('changes'))
          Change.fromJson(asJsonMap(item, 'change')),
      ],
      nextCursor: reader.integer('next_cursor'),
      hasMore: reader.boolean('has_more'),
    );
  }

  /// Keys read from `PullResponse`.
  static const Set<String> readKeys = {'changes', 'next_cursor', 'has_more'};

  /// Changes in journal order (parents before children).
  final List<Change> changes;

  /// Cursor to store and pass to the next pull.
  final int nextCursor;

  /// Whether another page follows.
  final bool hasMore;
}
