import 'fake_server.dart';
import 'sync_fixtures.dart';
import 'test_env.dart';

/// Another account whose profiles the default account sees in these tests.
const String relativeUserId = '0b000000-0000-4000-8000-00000000000b';

/// Ids of the entities [seedRelative] creates.
class RelativeIds {
  const RelativeIds({
    required this.profile,
    required this.medication,
    required this.schedule,
  });

  final String profile;
  final String medication;
  final String schedule;
}

/// A redacted `anonymous` medication as the server projects it for a viewer
/// or editor (`MedicationRedacted`).
Json redactedMedication(String profileId) => {
      'profile_id': profileId,
      'privacy': 'anonymous',
      'tz_mode': 'local',
      'fixed_tz': null,
      'redacted': true,
    };

/// A redacted schedule (`ScheduleRedacted`): the rule has no doses.
Json redactedSchedule(String medicationId, {String time = '08:00'}) => {
      'medication_id': medicationId,
      'redacted': true,
      'rule': {
        'v': 1,
        'kind': 'daily',
        'start_date': '2026-10-01',
        'end_date': null,
        'times': [
          {'time': time},
        ],
      },
    };

/// Seeds the `self` profile of [relativeUserId] with one medication and one
/// schedule, projected as the server shows them to [role] (`viewer`,
/// `editor` or `guardian`), and grants the default account that role.
/// [privacy] `anonymous` seeds the redacted forms.
RelativeIds seedRelative(
  TestEnv env, {
  String role = 'viewer',
  String privacy = 'shared',
  String suffix = '1',
}) {
  final ids = RelativeIds(
    profile: 'rel-profile-$suffix',
    medication: 'rel-medication-$suffix',
    schedule: 'rel-schedule-$suffix',
  );
  final key = env.clock.now;
  final server = env.server;
  server
    ..seed(
      'profile',
      ids.profile,
      user: relativeUserId,
      data: {
        'kind': 'self',
        'display_name': 'Relative $suffix',
        'timezone': 'Europe/Berlin',
      },
      key: key,
    )
    ..seed(
      'medication',
      ids.medication,
      user: relativeUserId,
      data: privacy == 'anonymous'
          ? redactedMedication(ids.profile)
          : medicationOut(ids.profile, name: 'Relative med $suffix'),
      key: privacy == 'anonymous' ? null : key,
    )
    ..seed(
      'schedule',
      ids.schedule,
      user: relativeUserId,
      data: privacy == 'anonymous'
          ? redactedSchedule(ids.medication)
          : {'medication_id': ids.medication, 'rule': dailyRule()},
      key: privacy == 'anonymous' ? null : key,
    )
    ..grant(ids.profile, FakeServer.defaultUserId, role);
  return ids;
}
