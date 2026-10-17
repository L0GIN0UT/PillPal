import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/push/push_payload.dart';
import 'package:pillpal_core/pillpal_core.dart';

const String _alert = '11111111-1111-4111-8111-111111111111';
const String _profile = '22222222-2222-4222-8222-222222222222';
const String _medication = '33333333-3333-4333-8333-333333333333';
const String _grant = '44444444-4444-4444-8444-444444444444';

Map<String, Object?> _missed({Map<String, Object?> extra = const {}}) => {
      'v': '1',
      't': 'missed',
      'a': _alert,
      'p': _profile,
      ...extra,
    };

Map<String, Object?> _link(String kind) => {
      'v': '1',
      't': kind,
      'g': _grant,
      'p': _profile,
    };

void main() {
  group('parsing a push', () {
    test('reads a missed alert with the optional medication', () {
      final payload = PushPayload.tryParse(_missed(extra: {'m': _medication}));
      expect(payload, isNotNull);
      expect(payload!.kind, PushKind.missed);
      expect(payload.alertId, _alert);
      expect(payload.profileId, _profile);
      expect(payload.medicationId, _medication);
      expect(payload.unconfirmed, isFalse);
    });

    test('reads the unconfirmed flag of a missed alert only', () {
      expect(
        PushPayload.tryParse(_missed(extra: {'s': 'u'}))!.unconfirmed,
        isTrue,
      );
      expect(
        PushPayload.tryParse({..._missed(), 't': 'resolved', 's': 'u'}),
        isNull,
      );
      expect(PushPayload.tryParse(_missed(extra: {'s': 'x'})), isNull);
    });

    test('reads resolved and both link kinds', () {
      expect(
        PushPayload.tryParse({..._missed(), 't': 'resolved'})!.kind,
        PushKind.resolved,
      );
      final accepted = PushPayload.tryParse(_link('link_accepted'))!;
      expect(accepted.kind, PushKind.linkAccepted);
      expect(accepted.grantId, _grant);
      expect(accepted.alertId, isNull);
      expect(
        PushPayload.tryParse(_link('link_restored'))!.kind,
        PushKind.linkRestored,
      );
    });

    test('accepts the version as a number (APNs custom keys)', () {
      expect(PushPayload.tryParse({..._missed(), 'v': 1}), isNotNull);
    });

    test('ignores an unknown kind', () {
      expect(PushPayload.tryParse({..._missed(), 't': 'promo'}), isNull);
      expect(PushPayload.tryParse({..._missed()}..remove('t')), isNull);
    });

    test('ignores another protocol version or none', () {
      expect(PushPayload.tryParse({..._missed(), 'v': '2'}), isNull);
      expect(PushPayload.tryParse({..._missed()}..remove('v')), isNull);
    });

    test('rejects keys the protocol does not have', () {
      expect(PushPayload.tryParse(_missed(extra: {'title': 'x'})), isNull);
      expect(PushPayload.tryParse(_missed(extra: {'aps': 'x'})), isNull);
    });

    test('rejects ids that are not UUIDs, missing or forbidden for the kind',
        () {
      expect(PushPayload.tryParse({..._missed(), 'a': 'not-a-uuid'}), isNull);
      expect(PushPayload.tryParse({..._missed()}..remove('a')), isNull);
      expect(PushPayload.tryParse({..._missed()}..remove('p')), isNull);
      expect(PushPayload.tryParse(_missed(extra: {'g': _grant})), isNull);
      expect(PushPayload.tryParse(_missed(extra: {'m': '12'})), isNull);
      expect(PushPayload.tryParse({..._link('link_accepted'), 'a': _alert}),
          isNull);
      expect(PushPayload.tryParse({..._link('link_accepted'), 'm': _alert}),
          isNull);
      expect(PushPayload.tryParse({..._link('link_accepted')}..remove('g')),
          isNull);
    });

    test('rejects values that are not strings', () {
      expect(PushPayload.tryParse({..._missed(), 'a': 5}), isNull);
      expect(PushPayload.tryParse({..._missed(), 'p': null}), isNull);
    });

    test('rejects no data at all', () {
      expect(PushPayload.tryParse(null), isNull);
      expect(PushPayload.tryParse(const {}), isNull);
    });

    test('lower-cases ids', () {
      const upper = 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA';
      final payload = PushPayload.tryParse({..._missed(), 'a': upper});
      expect(payload!.alertId, upper.toLowerCase());
    });
  });

  group('the local form', () {
    test('survives encode and decode', () {
      final payload = PushPayload.tryParse(
        _missed(extra: {'m': _medication, 's': 'u'}),
      )!;
      expect(PushPayload.tryDecode(payload.encode()), payload);
    });

    test('is not confused with the payload of a dose reminder', () {
      expect(PushPayload.tryDecode('{"k":"x/2026-10-16T08:00","m":"y"}'),
          isNull);
      expect(PushPayload.tryDecode('not json'), isNull);
      expect(PushPayload.tryDecode(null), isNull);
    });

    test('carries ids only', () {
      final raw = PushPayload.tryParse(_missed())!.encode();
      expect(raw, isNot(contains('name')));
      expect(raw, contains(_profile));
    });
  });

  group('the notification id', () {
    test('lies in the app range (ADR 0001 section 3)', () {
      for (final kind in ['missed', 'resolved']) {
        final id = PushPayload.tryParse({..._missed(), 't': kind})!
            .notificationId;
        expect(id, greaterThanOrEqualTo(firstAppNotificationId));
        expect(id, lessThanOrEqualTo(maxNotificationId));
      }
      expect(
        PushPayload.tryParse(_link('link_accepted'))!.notificationId,
        greaterThanOrEqualTo(firstAppNotificationId),
      );
    });

    test('is shared by missed and resolved of one alert', () {
      final missed = PushPayload.tryParse(_missed())!;
      final resolved = PushPayload.tryParse({..._missed(), 't': 'resolved'})!;
      expect(resolved.notificationId, missed.notificationId);
    });

    test('differs between alerts', () {
      final other = PushPayload.tryParse(
        {..._missed(), 'a': '55555555-5555-4555-8555-555555555555'},
      )!;
      expect(other.notificationId,
          isNot(PushPayload.tryParse(_missed())!.notificationId));
    });
  });
}
