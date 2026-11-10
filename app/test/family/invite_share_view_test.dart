import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/api/relatives_dto.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/features/common/local_time.dart';
import 'package:pillpal/src/features/common/status_pill.dart';
import 'package:pillpal/src/features/family/invite_share_view.dart';

import '../features/common/common_test_host.dart';

// The validity pill says the hour too when the invite lives a day or less
// (a guardian's, 24 h): a date alone would not tell tonight from tomorrow.

final DateTime _now = DateTime.utc(2026, 10, 20, 8);

Future<void> _pump(WidgetTester tester, Duration ttl) {
  return pumpThemed(
    tester,
    ProviderScope(
      overrides: [
        clockProvider.overrideWithValue(() => _now),
        deviceTimeZoneProvider.overrideWithValue('UTC'),
      ],
      child: InviteShareView(
        invite: InviteCreated(
          id: 'invite-1',
          role: 'viewer',
          expiresAt: _now.add(ttl),
          url: 'https://links-ru.pillpal.invalid/i#abcdefghijklmnopqrstuvwxyz',
        ),
        onDone: () {},
      ),
    ),
  );
}

String _pillText(WidgetTester tester) {
  final pill = find.byKey(const Key('invite-valid-until'));
  expect(tester.widget(pill), isA<StatusPill>());
  return tester.widget<StatusPill>(pill).label!;
}

void main() {
  testWidgets('a 24 hour invite shows the hour', (tester) async {
    await _pump(tester, const Duration(hours: 24));
    expect(_pillText(tester), contains('08:00'));
  });

  testWidgets('a 7 day invite shows the date only', (tester) async {
    await _pump(tester, const Duration(days: 7));
    expect(_pillText(tester), isNot(contains(':')));
  });
}
