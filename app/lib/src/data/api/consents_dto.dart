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

  /// The kinds the app collects at registration, in the order of the screen.
  static const List<ConsentKind> baseline = [
    ConsentKind.terms,
    ConsentKind.privacy,
    ConsentKind.healthData,
  ];
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
