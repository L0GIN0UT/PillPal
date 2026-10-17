import 'dart:ui';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/push/alert_local_data.dart';
import 'package:pillpal/src/push/alert_notification_sink.dart';
import 'package:pillpal/src/push/push_payload.dart';
import 'package:pillpal/src/push/relatives_alert_notifier.dart';
import 'package:pillpal/src/reminders/reminder_content.dart';
import 'package:pillpal_core/pillpal_core.dart';

const String _alert = '11111111-1111-4111-8111-111111111111';
const String _profile = '22222222-2222-4222-8222-222222222222';
const String _medication = '33333333-3333-4333-8333-333333333333';
const String _grant = '44444444-4444-4444-8444-444444444444';

class _FakeData implements AlertLocalData {
  String? name = 'Grace';
  AlertMedication? med = const AlertMedication(
    name: 'Synthetic Med',
    privacy: 'shared',
    redacted: false,
  );
  bool hideNames = false;
  DateTime? lastSeen;
  String? relative = 'Alex';

  @override
  Future<String?> profileName(String profileId) async =>
      profileId == _profile ? name : null;

  @override
  Future<AlertMedication?> medication(
    String profileId,
    String medicationId,
  ) async =>
      medicationId == _medication ? med : null;

  @override
  Future<bool> hideMedicationNames() async => hideNames;

  @override
  Future<DateTime?> ownerLastSeenAt(String profileId) async => lastSeen;

  @override
  Future<String?> relativeName(String grantId) async => relative;
}

class _FakeSink implements AlertNotificationSink {
  final Map<int, AlertNotification> tray = {};
  final List<AlertNotification> shown = [];

  @override
  Future<void> show(AlertNotification notification) async {
    shown.add(notification);
    tray[notification.id] = notification;
  }

  @override
  Future<bool> isShown(int id) async => tray.containsKey(id);
}

PushPayload _payload(
  String kind, {
  bool withMedication = false,
  bool unconfirmed = false,
}) =>
    PushPayload.tryParse({
      'v': '1',
      't': kind,
      if (kind == 'link_accepted' || kind == 'link_restored')
        'g': _grant
      else
        'a': _alert,
      'p': _profile,
      if (withMedication) 'm': _medication,
      if (unconfirmed) 's': 'u',
    })!;

void main() {
  late AppLocalizations strings;
  late _FakeData data;
  late _FakeSink sink;
  late RelativesAlertNotifier notifier;

  RelativesAlertNotifier build({
    AppLocalizations? l10n,
    DateTime Function(DateTime utc)? toLocal,
  }) =>
      RelativesAlertNotifier(
        data: data,
        sink: sink,
        strings: l10n ?? strings,
        toLocal: toLocal ?? (utc) => utc,
      );

  setUp(() {
    strings = reminderStrings(const Locale('en'));
    data = _FakeData();
    sink = _FakeSink();
    notifier = build();
  });

  group('a missed dose', () {
    test('names the relative and the medication from local data', () async {
      await notifier.handle(_payload('missed', withMedication: true));
      final note = sink.shown.single;
      expect(
        note.body,
        strings.relativesAlertMissedMedicationBody('Grace', 'Synthetic Med'),
      );
      expect(note.title, strings.relativesAlertMissedTitle);
    });

    test('names only the relative when the push has no medication', () async {
      await notifier.handle(_payload('missed'));
      expect(sink.shown.single.body, strings.relativesAlertMissedBody('Grace'));
    });

    test('hides the medication name when the device setting says so', () async {
      data.hideNames = true;
      await notifier.handle(_payload('missed', withMedication: true));
      final body = sink.shown.single.body;
      expect(body, strings.relativesAlertMissedBody('Grace'));
      expect(body, isNot(contains('Synthetic Med')));
    });

    test('never shows the name of an anonymous or hidden medication', () async {
      for (final privacy in ['anonymous', 'hidden']) {
        data.med = AlertMedication(
          name: 'Synthetic Med',
          privacy: privacy,
          redacted: false,
        );
        await notifier.handle(_payload('missed', withMedication: true));
        expect(sink.shown.last.body, isNot(contains('Synthetic Med')));
      }
    });

    test('never shows a redacted medication, even with a stored name',
        () async {
      data.med = const AlertMedication(
        name: 'Synthetic Med',
        privacy: 'shared',
        redacted: true,
      );
      await notifier.handle(_payload('missed', withMedication: true));
      expect(sink.shown.single.body, isNot(contains('Synthetic Med')));
    });

    test('falls back to the relative only when the medication is unknown',
        () async {
      data.med = null;
      await notifier.handle(_payload('missed', withMedication: true));
      expect(sink.shown.single.body, strings.relativesAlertMissedBody('Grace'));
    });

    test('is generic when the profile is not known locally', () async {
      data.name = null;
      await notifier.handle(_payload('missed', withMedication: true));
      final body = sink.shown.single.body;
      expect(body, strings.relativesAlertMissedGenericBody);
      expect(body, isNot(contains('Synthetic Med')));
    });

    test('uses the id range of the app and carries only ids in its payload',
        () async {
      await notifier.handle(_payload('missed', withMedication: true));
      final note = sink.shown.single;
      expect(note.id, greaterThanOrEqualTo(firstAppNotificationId));
      expect(note.id, lessThanOrEqualTo(maxNotificationId));
      expect(note.payload, isNot(contains('Grace')));
      expect(note.payload, isNot(contains('Synthetic Med')));
      expect(PushPayload.tryDecode(note.payload),
          _payload('missed', withMedication: true));
    });

    test('a repeated delivery replaces the notification, silently', () async {
      await notifier.handle(_payload('missed'));
      await notifier.handle(_payload('missed'));
      expect(sink.tray, hasLength(1));
      expect(sink.shown.first.quiet, isFalse);
      expect(sink.shown.last.quiet, isTrue);
    });
  });

  group('an unconfirmed alert', () {
    test('says the phone has not synced, with the rounded hour', () async {
      data.lastSeen = DateTime.utc(2026, 10, 16, 6);
      await notifier.handle(_payload('missed', unconfirmed: true));
      expect(
        sink.shown.single.body,
        strings.relativesAlertUnconfirmedBody('Grace', '06:00'),
      );
    });

    test('shows the hour on the wall clock of the device', () async {
      data.lastSeen = DateTime.utc(2026, 10, 16, 6);
      notifier = build(toLocal: (utc) => utc.add(const Duration(hours: 4)));
      await notifier.handle(_payload('missed', unconfirmed: true));
      expect(
        sink.shown.single.body,
        strings.relativesAlertUnconfirmedBody('Grace', '10:00'),
      );
    });

    test('rounds the hour down and pads it', () async {
      data.lastSeen = DateTime.utc(2026, 10, 16, 6, 40);
      await notifier.handle(_payload('missed', unconfirmed: true));
      expect(
        sink.shown.single.body,
        strings.relativesAlertUnconfirmedBody('Grace', '06:00'),
      );
    });

    test('does not name a medication', () async {
      data.lastSeen = DateTime.utc(2026, 10, 16, 6);
      await notifier.handle(
        _payload('missed', withMedication: true, unconfirmed: true),
      );
      expect(sink.shown.single.body, isNot(contains('Synthetic Med')));
    });

    test('without a known hour it does not invent one', () async {
      await notifier.handle(_payload('missed', unconfirmed: true));
      expect(
        sink.shown.single.body,
        strings.relativesAlertUnconfirmedNoTimeBody('Grace'),
      );
    });

    test('is generic without the name, with or without the hour', () async {
      data.name = null;
      data.lastSeen = DateTime.utc(2026, 10, 16, 6);
      await notifier.handle(_payload('missed', unconfirmed: true));
      expect(
        sink.shown.last.body,
        strings.relativesAlertUnconfirmedGenericBody('06:00'),
      );
      data.lastSeen = null;
      await notifier.handle(_payload('missed', unconfirmed: true));
      expect(sink.shown.last.body, strings.relativesAlertMissedGenericBody);
    });
  });

  group('a resolved alert', () {
    test('replaces the missed notification in place and quietly', () async {
      await notifier.handle(_payload('missed', withMedication: true));
      final missed = sink.shown.single;
      await notifier.handle(_payload('resolved'));
      final resolved = sink.shown.last;
      expect(resolved.id, missed.id);
      expect(resolved.quiet, isTrue);
      expect(resolved.title, strings.relativesAlertResolvedTitle);
      expect(resolved.body, strings.relativesAlertResolvedBody('Grace'));
      expect(resolved.body, isNot(contains('Synthetic Med')));
      expect(sink.tray, hasLength(1));
    });

    test('does nothing when the missed notification is gone', () async {
      await notifier.handle(_payload('resolved'));
      expect(sink.shown, isEmpty);
    });

    test('is generic when the profile is not known', () async {
      await notifier.handle(_payload('missed'));
      data.name = null;
      await notifier.handle(_payload('resolved'));
      expect(sink.shown.last.body, strings.relativesAlertResolvedGenericBody);
    });
  });

  group('link changes', () {
    test('an accepted invite names the relative when the link is known',
        () async {
      await notifier.handle(_payload('link_accepted'));
      expect(
        sink.shown.single.body,
        strings.relativesAlertLinkAcceptedBody('Alex'),
      );
      expect(sink.shown.single.title, strings.relativesAlertLinkAcceptedTitle);
    });

    test('is generic while the link is not stored yet', () async {
      data.relative = null;
      await notifier.handle(_payload('link_accepted'));
      expect(
        sink.shown.single.body,
        strings.relativesAlertLinkAcceptedGenericBody,
      );
    });

    test('a restored account says so', () async {
      await notifier.handle(_payload('link_restored'));
      expect(
        sink.shown.single.body,
        strings.relativesAlertLinkRestoredBody('Alex'),
      );
      data.relative = null;
      await notifier.handle(_payload('link_restored'));
      expect(
        sink.shown.last.body,
        strings.relativesAlertLinkRestoredGenericBody,
      );
    });

    test('uses an id of the app range, apart from the dose alerts', () async {
      await notifier.handle(_payload('link_accepted'));
      expect(
          sink.shown.single.id, greaterThanOrEqualTo(firstAppNotificationId));
      expect(sink.shown.single.id, _payload('link_accepted').notificationId);
    });
  });

  group('in Russian', () {
    test('renders from the same data', () async {
      final russian = reminderStrings(const Locale('ru'));
      notifier = build(l10n: russian);
      await notifier.handle(_payload('missed', withMedication: true));
      expect(
        sink.shown.single.body,
        russian.relativesAlertMissedMedicationBody('Grace', 'Synthetic Med'),
      );
      expect(sink.shown.single.body,
          isNot(strings.relativesAlertMissedBody('Grace')));
    });
  });

  group('the notification details', () {
    AndroidNotificationDetails details({bool quiet = false}) {
      final platform = alertNotificationDetails(
        AlertNotification(
          id: 1,
          title: 'T',
          body: 'B',
          payload: '{}',
          quiet: quiet,
        ),
        strings,
      );
      return platform.android!;
    }

    test('use the private channel and hide the content on a secure screen', () {
      final android = details();
      expect(android.channelId, relativesAlertsChannelId);
      expect(relativesAlertsChannelId, 'relatives_alerts_v1');
      expect(android.visibility, NotificationVisibility.private);
      expect(android.importance, Importance.high);
      expect(android.silent, isFalse);
    });

    test('a quiet notification makes no sound', () {
      final android = details(quiet: true);
      expect(android.silent, isTrue);
      expect(android.onlyAlertOnce, isTrue);
    });
  });
}
