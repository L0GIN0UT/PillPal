import 'fake_server.dart';

/// A rejected mutation result.
Json rejected(Json m, String code, {Json? current}) => {
      'entity': m['entity'],
      'id': m['id'],
      'status': 'rejected',
      'code': code,
      'version': null,
      'current': current,
    };

/// `MedicationOut` with defaults.
Json medicationOut(String profileId, {String name = 'Med A'}) => {
      'profile_id': profileId,
      'name': name,
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
      'version': 2,
      'created_at': '2026-10-16T09:00:00Z',
      'updated_at': '2026-10-16T09:00:00Z',
    };
