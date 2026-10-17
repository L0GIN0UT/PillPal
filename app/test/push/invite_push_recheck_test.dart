import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/features/family/family_providers.dart';
import 'package:pillpal/src/push/push_need_provider.dart';

import '../helpers.dart';

void main() {
  test('creating an invite makes the push need look at invites again',
      () async {
    final harness = TestHarness(
      handler: (request) async => jsonResponse({
        'id': 'created-1',
        'role': 'viewer',
        'expires_at': '2026-10-23T08:00:00Z',
        'url': 'https://links-ru.pillpal.invalid/i#abcdefghijklmnopqrstuvwxyz012345',
      }, 201),
    );
    final container = createContainer(harness);
    expect(container.read(pushRecheckProvider), 0);

    await container.read(familyActionsProvider).createInvite(
          profileId: 'profile-1',
          inviteId: 'invite-1',
          role: 'viewer',
          disclosureVersion: 1,
        );

    expect(container.read(pushRecheckProvider), 1);
  });
}
