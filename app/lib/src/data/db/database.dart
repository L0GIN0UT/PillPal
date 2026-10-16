import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'tables.dart';

export 'tables.dart';

part 'database.g.dart';

/// The app's local database (offline-first: the UI reads only from here).
@DriftDatabase(
  tables: [Profiles, Medications, Schedules, DoseEvents, Outbox, SyncState],
)
class AppDatabase extends _$AppDatabase {
  /// Opens a database on [executor] (`NativeDatabase.memory()` in tests).
  AppDatabase(super.executor);

  /// Opens the on-device database file.
  factory AppDatabase.open() => AppDatabase(driftDatabase(name: 'pillpal'));

  /// Bump on every schema change and add a step to [_upgrade].
  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (migrator) => migrator.createAll(),
        onUpgrade: _upgrade,
      );

  /// Schema upgrade hook: one `if (from < N)` block per version, in order.
  Future<void> _upgrade(Migrator migrator, int from, int to) async {
    if (from > to) {
      throw StateError('Cannot downgrade the database from $from to $to');
    }
    // Version 1 is the first schema; future steps go here.
  }
}
