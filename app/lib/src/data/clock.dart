import 'package:uuid/uuid.dart';

/// Source of the current instant; injected so tests control time.
typedef Clock = DateTime Function();

/// Generates entity ids.
typedef IdGenerator = String Function();

/// The device clock, in UTC.
DateTime systemClock() => DateTime.now().toUtc();

const Uuid _uuid = Uuid();

/// A random lowercase UUID v4 (the canonical form the server requires).
String newUuid() => _uuid.v4();

/// The device clock corrected by the server's clock.
///
/// The server rejects conflict keys and dose times more than 10 minutes in
/// its future (`clock_skew`), so a device whose clock runs ahead would block
/// its outbox. [ApiClient] reports the HTTP `Date` of every response through
/// [observe]; [now] then applies the measured offset. Offsets below
/// [threshold] are ignored: `Date` has one-second resolution and includes
/// network latency, and small skews are harmless.
class ServerClock {
  /// Creates a clock over the [device] clock.
  ServerClock([this._device = systemClock]);

  /// Smallest offset that is applied.
  static const Duration threshold = Duration(minutes: 1);

  final Clock _device;
  Duration _offset = Duration.zero;

  /// Server time minus device time, as last measured.
  Duration get offset => _offset;

  /// The uncorrected device time.
  DateTime deviceNow() => _device();

  /// Best estimate of the server's current time (UTC).
  DateTime now() {
    final device = _device();
    return _offset.abs() >= threshold ? device.add(_offset) : device;
  }

  /// Records that the server's clock read [serverTime] at [deviceTime].
  void observe(DateTime serverTime, DateTime deviceTime) {
    _offset = serverTime.toUtc().difference(deviceTime.toUtc());
  }
}
