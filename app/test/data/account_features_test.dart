import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/api/relatives_dto.dart';

// `GET /v1/me/features` also carries the deletion terms the dialog states
// (ADR 0010 §4): the app never hard-codes them.

void main() {
  test('reads the deletion terms the server states', () {
    final features = AccountFeatures.fromJson(const {
      'soft_limits_enabled': false,
      'relatives_limit': null,
      'pdf_reports_limit': null,
      'account_deletion_grace_days': 14,
      'managed_archive_retention_days': 90,
    });

    expect(features.accountDeletionGraceDays, 14);
    expect(features.managedArchiveRetentionDays, 90);
  });

  test('without an answer the grace is the legal maximum, retention unknown',
      () {
    const offline = AccountFeatures();

    expect(offline.accountDeletionGraceDays, 30);
    expect(offline.managedArchiveRetentionDays, isNull);
    final partial = AccountFeatures.fromJson(const {
      'soft_limits_enabled': false,
      'relatives_limit': null,
      'pdf_reports_limit': null,
    });
    expect(partial.accountDeletionGraceDays, 30);
    expect(partial.managedArchiveRetentionDays, isNull);
  });
}
