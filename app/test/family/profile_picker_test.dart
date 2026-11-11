import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/features/family/profile_context.dart';
import 'package:pillpal/src/features/family/profile_picker.dart';

// The pure state behind the profile chips and the header button. Synthetic
// profiles only.

ProfileAccess _access(String id, String kind, String name) => ProfileAccess(
      profile: ProfileRow(
        id: id,
        kind: kind,
        displayName: name,
        timezone: 'Europe/Moscow',
        clientUpdatedAt: 1,
        updatedByDevice: 'd',
        missedAlertMinutes: 30,
        missedAlertsEnabled: true,
      ),
      role: 'owner',
    );

void main() {
  final own = _access('self-1', 'self', 'Test User');
  final ward = _access('ward-1', 'managed', 'Pat Ward');

  test('one person: no picker', () {
    expect(ProfilePicker.of([own], null, meLabel: 'Me'), isNull);
    expect(ProfilePicker.of(null, null, meLabel: 'Me'), isNull);
  });

  test('the own profile is shown while nothing else is selected', () {
    final picker = ProfilePicker.of([own, ward], null, meLabel: 'Me')!;
    expect(picker.currentId, 'self-1');
    expect(picker.currentLabel, 'Me');
    expect(picker.items.map((i) => i.label), ['Me', 'Pat Ward']);
  });

  test('a selection that is gone falls back to the own profile', () {
    final picker = ProfilePicker.of([own, ward], 'gone', meLabel: 'Me')!;
    expect(picker.currentId, 'self-1');
  });

  test('selecting the own profile stores null, another stores its id', () {
    final picker = ProfilePicker.of([own, ward], 'ward-1', meLabel: 'Me')!;
    expect(picker.currentLabel, 'Pat Ward');
    expect(picker.selectionOf('self-1'), isNull);
    expect(picker.selectionOf('ward-1'), 'ward-1');
  });
}
