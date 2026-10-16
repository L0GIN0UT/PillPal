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
