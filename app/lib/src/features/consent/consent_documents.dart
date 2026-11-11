import 'package:flutter/foundation.dart';
import 'package:pillpal_core/pillpal_core.dart';

import '../../data/api/consents_dto.dart';

/// A consent text as the app displays it: its [kind], the [version] the app
/// sends with the acceptance and the date that version was written.
@immutable
class ConsentDocument {
  /// Creates a document description.
  const ConsentDocument({
    required this.kind,
    required this.version,
    required this.effectiveFrom,
  });

  /// What the text is.
  final ConsentKind kind;

  /// Version of the text, sent as `ConsentIn.version`.
  final int version;

  /// Day this version took effect, shown as «Version of …».
  final LocalDate effectiveFrom;

  @override
  bool operator ==(Object other) =>
      other is ConsentDocument &&
      other.kind == kind &&
      other.version == version &&
      other.effectiveFrom == effectiveFrom;

  @override
  int get hashCode => Object.hash(kind, version, effectiveFrom);
}

/// The build serves a region that has no consent texts.
class UnknownConsentRegion implements Exception {
  /// Creates the error.
  const UnknownConsentRegion();

  @override
  String toString() => 'UnknownConsentRegion';
}

/// The consent texts of each region (ADR 0016 §1, docs/phase5-plan.md A1).
///
/// There are no web pages yet: the texts are versioned stubs in the ARB files
/// (`consentText<Kind>Body`). A version covers every language of its text, and
/// a text change means a new version, never an edit. The versions mirror the
/// server's `CONSENT_VERSIONS_*` defaults of that region; if the server moves
/// on, it answers 422 `unsupported_consent_version` and the app asks for an
/// update. Region deployments may diverge, hence one table per region.
abstract final class ConsentDocuments {
  static final LocalDate _stubDate = LocalDate(2026, 11, 1);

  static final Map<ConsentKind, ConsentDocument> _baseline = {
    for (final kind in ConsentKind.baseline)
      kind: ConsentDocument(kind: kind, version: 1, effectiveFrom: _stubDate),
  };

  static final Map<String, Map<ConsentKind, ConsentDocument>> _byRegion = {
    'ru': _baseline,
    'eu': _baseline,
  };

  /// The texts shown for [region] (`ru` or `eu`). A build of any other region
  /// must not silently accept the texts of another one: it throws
  /// [UnknownConsentRegion].
  static Map<ConsentKind, ConsentDocument> forRegion(String region) {
    final documents = _byRegion[region];
    if (documents == null) {
      throw const UnknownConsentRegion();
    }
    return documents;
  }

  /// What the user accepts at registration in [region]: every baseline text
  /// with the version the app displays.
  static List<ConsentGrant> grantsFor(String region) => [
        for (final document in forRegion(region).values)
          ConsentGrant(kind: document.kind, version: document.version),
      ];
}
