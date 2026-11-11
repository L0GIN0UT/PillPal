import 'json.dart';

// Wire forms of the account endpoints (backend/app/schemas/relatives.py,
// docs/adr/0010).

/// What to gate in the UI and which deletion terms to state
/// (`FeaturesOut`).
class AccountFeatures {
  /// Creates the features; the default has no limits and, as the deletion
  /// terms are unknown, the longest grace the server allows.
  const AccountFeatures({
    this.softLimitsEnabled = false,
    this.relativesLimit,
    this.pdfReportsLimit,
    this.accountDeletionGraceDays = maxDeletionGraceDays,
    this.managedArchiveRetentionDays,
    this.catalogContributionsEnabled = false,
    this.dataExportEnabled = false,
  });

  /// The server validates the grace to 1..30 days (152-FZ art. 21(5)): the
  /// safe thing to say while the real value is unknown.
  static const int maxDeletionGraceDays = 30;

  /// Parses `FeaturesOut`.
  factory AccountFeatures.fromJson(JsonMap json) {
    final reader = JsonReader(json, readKeys);
    final grace = reader.integerOrNull('account_deletion_grace_days');
    final retention = reader.integerOrNull('managed_archive_retention_days');
    final flag = reader.booleanOrNull('catalog_contributions_enabled');
    final export = reader.booleanOrNull('data_export_enabled');
    return AccountFeatures(
      softLimitsEnabled: reader.boolean('soft_limits_enabled'),
      relativesLimit: reader.integerOrNull('relatives_limit'),
      pdfReportsLimit: reader.integerOrNull('pdf_reports_limit'),
      accountDeletionGraceDays: grace ?? maxDeletionGraceDays,
      managedArchiveRetentionDays: retention,
      catalogContributionsEnabled: flag ?? false,
      dataExportEnabled: export ?? false,
    );
  }

  /// Keys read from `FeaturesOut`.
  static const Set<String> readKeys = {
    'soft_limits_enabled',
    'relatives_limit',
    'pdf_reports_limit',
    'account_deletion_grace_days',
    'managed_archive_retention_days',
    'catalog_contributions_enabled',
    'data_export_enabled',
  };

  /// Whether the soft limits are on at all.
  final bool softLimitsEnabled;

  /// Active relatives allowed on the account's profiles; null without limit.
  final int? relativesLimit;

  /// PDF reports allowed; null without limit.
  final int? pdfReportsLimit;

  /// Erasure completes no later than this many days after a request.
  final int accountDeletionGraceDays;

  /// Days an archived managed profile is kept for its co-guardians; null
  /// while unknown (offline).
  final int? managedArchiveRetentionDays;

  /// Whether the server accepts the contribution consent of a GTIN link
  /// (ADR 0015 §4); false for an older server.
  final bool catalogContributionsEnabled;

  /// Whether the account data export is on (ADR 0016 §8); false for an older
  /// server, and while the answer is unknown (offline).
  final bool dataExportEnabled;

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
