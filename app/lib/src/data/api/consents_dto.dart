import 'json.dart';

/// Kind of a consent record (`ConsentIn.kind`, ADR 0016 §1).
enum ConsentKind {
  /// Processing of health data (medications, schedules, dose events).
  healthData('health_data'),

  /// Terms of use.
  terms('terms'),

  /// Privacy policy.
  privacy('privacy'),

  /// Anonymous counting of GTIN links; recorded through a medication link,
  /// never offered at registration.
  catalogContribution('catalog_contribution');

  const ConsentKind(this.wire);

  /// Value on the wire.
  final String wire;

  /// The kind with wire value [wire], or null for one this app does not know.
  static ConsentKind? tryParse(String wire) {
    for (final kind in values) {
      if (kind.wire == wire) {
        return kind;
      }
    }
    return null;
  }

  /// The kinds the app collects at registration, in the order of the screen.
  static const List<ConsentKind> baseline = [
    ConsentKind.terms,
    ConsentKind.privacy,
    ConsentKind.healthData,
  ];
}

/// Error codes of the consent endpoints the app reacts to.
abstract final class ConsentErrors {
  /// The server no longer accepts the version the app sent (422).
  static const String unsupportedVersion = 'unsupported_consent_version';

  /// A registration without the required consents (422).
  static const String required = 'consent_required';

  /// Whether [code] means the consent versions of this app are not accepted:
  /// the app is out of date.
  static bool isRefusal(String code) =>
      code == unsupportedVersion || code == required;
}

/// One accepted text: its kind and the version the app displayed
/// (`ConsentIn`). The server sets the time; the client never sends it.
class ConsentGrant {
  /// Creates a grant.
  const ConsentGrant({required this.kind, required this.version});

  /// What was accepted.
  final ConsentKind kind;

  /// Version of the text the user saw, 1..1000.
  final int version;

  /// Wire form.
  JsonMap toJson() => {'kind': kind.wire, 'version': version};
}

/// One stored consent record (`ConsentRecordOut`); withdrawn ones stay in the
/// list as history.
class ConsentRecord {
  /// Creates a record.
  const ConsentRecord({
    required this.id,
    required this.kind,
    required this.version,
    required this.source,
    required this.acceptedAt,
    required this.withdrawnAt,
  });

  /// Parses `ConsentRecordOut`.
  factory ConsentRecord.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    return ConsentRecord(
      id: reader.string('id'),
      kind: reader.string('kind'),
      version: reader.integer('version'),
      source: reader.string('source'),
      acceptedAt: reader.instant('accepted_at'),
      withdrawnAt: reader.instantOrNull('withdrawn_at'),
    );
  }

  /// Keys read from `ConsentRecordOut`.
  static const Set<String> readKeys = {
    'id',
    'kind',
    'version',
    'source',
    'accepted_at',
    'withdrawn_at',
  };

  /// Opaque record id.
  final String id;

  /// Wire value of the kind (a newer server may know kinds this app does not).
  final String kind;

  /// Version of the text that was accepted.
  final int version;

  /// Where it was accepted (`registration`, `in_app`, ...).
  final String source;

  /// When the server recorded it.
  final DateTime acceptedAt;

  /// When it was withdrawn, if it was.
  final DateTime? withdrawnAt;
}

/// What the server holds for the account (`ConsentsOut`, ADR 0016 §2).
class ConsentsState {
  /// Creates a state.
  const ConsentsState({
    required this.current,
    required this.records,
    required this.missing,
  });

  /// Parses `ConsentsOut`.
  factory ConsentsState.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    final current = <String, int>{};
    for (final entry in reader.object('current').entries) {
      final version = entry.value;
      if (version is! int) {
        throw const FormatException('Expected an integer at "current"');
      }
      current[entry.key] = version;
    }
    return ConsentsState(
      current: current,
      records: [
        for (final item in reader.list('records'))
          ConsentRecord.fromJson(asJsonMap(item, 'consent record')),
      ],
      missing: [
        for (final item in reader.list('missing'))
          item is String
              ? item
              : throw const FormatException('Expected a string at "missing"'),
      ],
    );
  }

  /// Keys read from `ConsentsOut`.
  static const Set<String> readKeys = {'current', 'records', 'missing'};

  /// The version the app must show, per kind (wire value).
  final Map<String, int> current;

  /// Every record, withdrawn ones included.
  final List<ConsentRecord> records;

  /// Required kinds (wire values) with no active record of the current
  /// version.
  final List<String> missing;
}
