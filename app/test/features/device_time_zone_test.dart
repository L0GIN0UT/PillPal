import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/features/common/local_time.dart';

final DateTime _now = DateTime.utc(2026, 10, 25, 12);

ProviderContainer _containerWith(Future<String?> Function() reader) {
  final container = ProviderContainer(
    overrides: [
      timeZoneReaderProvider.overrideWithValue(reader),
      clockProvider.overrideWithValue(() => _now),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('the device zone is the IANA zone the platform reports', () async {
    final container = _containerWith(() async => 'Europe/Berlin');
    expect(container.read(deviceTimeZoneReadyProvider), isFalse);

    await container.read(platformTimeZoneProvider.future);

    expect(container.read(deviceTimeZoneProvider), 'Europe/Berlin');
    expect(container.read(deviceTimeZoneReadyProvider), isTrue);
  });

  test('an unknown zone falls back to the current offset', () async {
    final container = _containerWith(() async => 'Not/A_Zone');

    expect(await container.read(platformTimeZoneProvider.future), isNull);
    expect(
      container.read(deviceTimeZoneProvider),
      guessDeviceTimeZone(_now.toLocal()),
    );
    expect(container.read(deviceTimeZoneReadyProvider), isTrue);
  });

  test('invalidating re-reads the zone (after travelling)', () async {
    var zone = 'Europe/Berlin';
    final container = _containerWith(() async => zone);
    await container.read(platformTimeZoneProvider.future);

    zone = 'Asia/Tokyo';
    container.invalidate(platformTimeZoneProvider);
    await container.read(platformTimeZoneProvider.future);

    expect(container.read(deviceTimeZoneProvider), 'Asia/Tokyo');
  });
}
