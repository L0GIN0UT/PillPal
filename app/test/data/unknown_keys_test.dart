import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/api/relatives_dto.dart';
import 'package:pillpal/src/data/sync/server_rows.dart';

// Backend milestone 4.6 adds catalog references and the contribution consent
// to `MedicationOut` and a flag to `FeaturesOut` (ADR 0015 §4). Installed
// builds that predate them must read those payloads unchanged: the readers
// only look at declared keys and ignore the rest.

void main() {
  test('a pulled medication with catalog fields is read without them', () {
    final row = medicationRow(
      'med-1',
      const {
        'profile_id': 'profile-1',
        'name': 'Synthetic Tablet',
        'form': null,
        'strength_text': null,
        'notes': null,
        'tz_mode': 'local',
        'fixed_tz': null,
        'stock_count': null,
        'stock_unit': null,
        'low_stock_days': null,
        'stock_set_at': null,
        'privacy': 'shared',
        'catalog_product_id': '5b0f4a52-8e1b-4f60-9d3b-0a2f3c9d1e11',
        'catalog_package_id': null,
        'catalog_composition_id': null,
        'gtin': '04600000000011',
        'manual_ingredients': [
          {'substance_id': null, 'name': 'Synthetic', 'strength_text': null},
        ],
        'gtin_link_shared': true,
        'gtin_link_consent_version': 1,
        'gtin_link_consented_at': '2026-11-09T10:00:00Z',
        'version': 3,
      },
      const RowKey(1, 'device-1'),
    );

    expect(row.name, 'Synthetic Tablet');
    expect(row.privacy, 'shared');
  });

  test('features with the contribution flag are read without it', () {
    final features = AccountFeatures.fromJson(const {
      'soft_limits_enabled': false,
      'relatives_limit': null,
      'pdf_reports_limit': null,
      'account_deletion_grace_days': 30,
      'managed_archive_retention_days': 365,
      'catalog_contributions_enabled': false,
    });

    expect(features.accountDeletionGraceDays, 30);
  });
}
