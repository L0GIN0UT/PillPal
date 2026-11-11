import 'package:drift/drift.dart';

// Device-side report history (schema version 9, docs/adr/0019). One row per
// PDF kept on this device; the file itself lives in the app's private
// storage. Rows hold dates and sizes only: no medication names, no patient
// name. Wiped with the account's data, and per scope when access ends.

/// A doctor's report kept on this device ("Мои отчёты").
@DataClassName('StoredReport')
class StoredReports extends Table {
  /// Client-generated UUID; also the folder name of the file.
  TextColumn get id => text()();

  /// Profile the report is of (a relative's report goes with its scope).
  TextColumn get profileId => text()();

  /// First day of the period, `YYYY-MM-DD`.
  TextColumn get firstDay => text()();

  /// Last day of the period, `YYYY-MM-DD`.
  TextColumn get lastDay => text()();

  /// Whether `hidden` medications were included.
  BoolColumn get includeHidden => boolean()();

  /// When it was made (microseconds, UTC).
  IntColumn get createdAt => integer()();

  /// Size of the PDF file in bytes.
  IntColumn get sizeBytes => integer()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
