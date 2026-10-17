import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/push/resolved_alerts.dart';

import '../data/test_env.dart' show FakeClock;

const String _alert = '11111111-1111-4111-8111-111111111111';
const String _other = '22222222-2222-4222-8222-222222222222';

void main() {
  late Directory directory;
  late FakeClock clock;

  FileResolvedAlerts build({int maxEntries = 200}) => FileResolvedAlerts(
        directory: () async => directory,
        clock: clock.call,
        maxEntries: maxEntries,
      );

  setUp(() {
    directory = Directory.systemTemp.createTempSync('resolved_alerts_test');
    clock = FakeClock(DateTime.utc(2026, 10, 17, 9));
  });

  tearDown(() => directory.deleteSync(recursive: true));

  test('nothing is resolved at first', () async {
    expect(await build().wasResolved(_alert), isFalse);
  });

  test('a remembered alert is resolved, others are not', () async {
    final alerts = build();
    await alerts.remember(_alert);
    expect(await alerts.wasResolved(_alert), isTrue);
    expect(await alerts.wasResolved(_other), isFalse);
  });

  test('it survives another instance: the background isolate has its own',
      () async {
    await build().remember(_alert);
    expect(await build().wasResolved(_alert), isTrue);
  });

  test('it is forgotten after the time to live', () async {
    final alerts = build();
    await alerts.remember(_alert);
    clock.advance(resolvedAlertMemory - const Duration(minutes: 1));
    expect(await alerts.wasResolved(_alert), isTrue);
    clock.advance(const Duration(minutes: 2));
    expect(await alerts.wasResolved(_alert), isFalse);
  });

  test('expired entries are dropped when something is remembered', () async {
    final alerts = build();
    await alerts.remember(_alert);
    clock.advance(resolvedAlertMemory + const Duration(hours: 1));
    await alerts.remember(_other);
    final files = directory.listSync().whereType<File>().toList();
    expect(files, hasLength(1));
    expect(files.single.readAsStringSync(), isNot(contains(_alert)));
  });

  test('the oldest entries go first when the memory is full', () async {
    final alerts = build(maxEntries: 2);
    await alerts.remember('a');
    clock.advance(const Duration(minutes: 1));
    await alerts.remember('b');
    clock.advance(const Duration(minutes: 1));
    await alerts.remember('c');
    expect(await alerts.wasResolved('a'), isFalse);
    expect(await alerts.wasResolved('b'), isTrue);
    expect(await alerts.wasResolved('c'), isTrue);
  });

  test('a damaged file counts as empty and is overwritten', () async {
    final alerts = build();
    await alerts.remember(_alert);
    for (final file in directory.listSync().whereType<File>()) {
      file.writeAsStringSync('{not json');
    }
    expect(await alerts.wasResolved(_alert), isFalse);
    await alerts.remember(_other);
    expect(await alerts.wasResolved(_other), isTrue);
  });

  test('a failing disk never throws: the alert is then simply shown',
      () async {
    final alerts = FileResolvedAlerts(
      directory: () async => throw const FileSystemException('no disk'),
      clock: clock.call,
    );
    await alerts.remember(_alert);
    expect(await alerts.wasResolved(_alert), isFalse);
  });
}
