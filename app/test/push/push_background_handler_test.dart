import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/l10n/gen/app_localizations.dart';
import 'package:pillpal/src/push/alert_local_data.dart';
import 'package:pillpal/src/push/alert_notification_sink.dart';
import 'package:pillpal/src/push/push_background_handler.dart';
import 'package:pillpal/src/push/relatives_alert_notifier.dart';
import 'package:pillpal/src/reminders/reminder_content.dart';

const String _alert = '11111111-1111-4111-8111-111111111111';
const String _profile = '22222222-2222-4222-8222-222222222222';

class _Data implements AlertLocalData {
  _Data({this.fail = false});

  final bool fail;

  @override
  Future<String?> profileName(String profileId) async {
    if (fail) {
      throw StateError('database is gone');
    }
    return 'Grace';
  }

  @override
  Future<AlertMedication?> medication(String p, String m) async => null;

  @override
  Future<bool> hideMedicationNames() async => false;

  @override
  Future<DateTime?> ownerLastSeenAt(String profileId) async => null;

  @override
  Future<String?> relativeName(String grantId) async => null;
}

class _Sink implements AlertNotificationSink {
  final List<AlertNotification> shown = [];

  @override
  Future<void> show(AlertNotification notification) async =>
      shown.add(notification);

  @override
  Future<bool> isShown(int id) async => false;
}

void main() {
  late AppLocalizations strings;
  late _Sink sink;
  late int opened;
  late int closed;

  Future<void> run(Map<String, String> data, {bool failing = false}) =>
      handlePushData(
        data,
        strings: strings,
        openData: () async {
          opened++;
          return _Data(fail: failing);
        },
        openSink: (_) => sink,
        close: () async => closed++,
      );

  setUp(() {
    strings = reminderStrings(const Locale('en'));
    sink = _Sink();
    opened = 0;
    closed = 0;
  });

  test('a push of this app becomes a notification, then the db is closed',
      () async {
    await run({'v': '1', 't': 'missed', 'a': _alert, 'p': _profile});
    expect(sink.shown.single.body, strings.relativesAlertMissedBody('Grace'));
    expect(closed, 1);
  });

  test('an unknown kind is ignored without touching the database', () async {
    await run({'v': '1', 't': 'something_new', 'a': _alert, 'p': _profile});
    expect(sink.shown, isEmpty);
    expect(opened, 0);
  });

  test('foreign data is ignored', () async {
    await run({'hello': 'world'});
    await run({'v': '1', 't': 'missed', 'a': 'not-a-uuid', 'p': _profile});
    expect(sink.shown, isEmpty);
    expect(opened, 0);
  });

  test('a failing database never throws and still closes', () async {
    await run(
      {'v': '1', 't': 'missed', 'a': _alert, 'p': _profile},
      failing: true,
    );
    expect(sink.shown, isEmpty);
    expect(closed, 1);
  });
}
