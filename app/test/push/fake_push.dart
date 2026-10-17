import 'dart:async';

import 'package:pillpal/src/push/push_api.dart';
import 'package:pillpal/src/push/push_need.dart';
import 'package:pillpal/src/push/push_provider_client.dart';

/// A provider client that records its use and hands out a scripted token.
class FakePushClient implements PushProviderClient {
  FakePushClient(
    this.kind, {
    this.available = true,
    this.token = 'synthetic-token-1',
    this.environment,
    this.rendersLocally = true,
  });

  @override
  final PushProviderKind kind;

  @override
  final bool rendersLocally;

  bool available;
  String? token;
  String? environment;

  /// When set, [isAvailable] throws it.
  Object? availabilityError;

  /// When set, [start] throws it.
  Object? startError;

  int starts = 0;
  int stops = 0;
  final StreamController<PushRegistration> refreshController =
      StreamController<PushRegistration>.broadcast();
  final StreamController<Map<String, String>> messageController =
      StreamController<Map<String, String>>.broadcast();

  @override
  Future<bool> isAvailable() async {
    final error = availabilityError;
    if (error != null) {
      throw error;
    }
    return available;
  }

  @override
  Future<PushRegistration?> start() async {
    starts++;
    final error = startError;
    if (error != null) {
      throw error;
    }
    final value = token;
    return value == null
        ? null
        : PushRegistration(token: value, apnsEnvironment: environment);
  }

  @override
  Stream<PushRegistration> get refreshes => refreshController.stream;

  @override
  Stream<Map<String, String>> get messages => messageController.stream;

  @override
  Future<void> stop() async {
    stops++;
  }

  Future<void> dispose() async {
    await refreshController.close();
    await messageController.close();
  }
}

/// Records registrations and removals; can fail like an offline device.
class FakeTokenGateway implements PushTokenGateway {
  final List<({PushProviderKind provider, PushRegistration registration})>
      registered = [];
  final List<String?> registeredFor = [];
  int unregistered = 0;

  /// When set, both calls throw it.
  Object? error;

  @override
  Future<void> register({
    required PushProviderKind provider,
    required PushRegistration registration,
    String? forUser,
  }) async {
    final failure = error;
    if (failure != null) {
      throw failure;
    }
    registered.add((provider: provider, registration: registration));
    registeredFor.add(forUser);
  }

  @override
  Future<void> unregister({String? forUser}) async {
    final failure = error;
    if (failure != null) {
      throw failure;
    }
    unregistered++;
  }
}

/// A need that tests flip.
class FakePushNeed implements PushNeed {
  FakePushNeed([this.needed = false]);

  bool? needed;
  int invitesChangedCalls = 0;

  @override
  Future<bool?> isNeeded() async => needed;

  @override
  void invitesChanged() {
    invitesChangedCalls++;
  }
}
