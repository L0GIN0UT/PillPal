import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/api/api_exception.dart';
import '../data/clock.dart';
import 'push_api.dart';
import 'push_need.dart';
import 'push_provider_client.dart';
import 'push_state_store.dart';

/// Where relative alerts stand on this device.
enum PushAvailability {
  /// No alerts are needed (nothing is registered), or nobody is signed in.
  idle,

  /// A token is registered: the server can alert this device.
  registered,

  /// Alerts are needed but this device has no provider: no Google services
  /// with a Firebase project, no RuStore. The Family tab says so.
  unavailable,

  /// A step failed (offline, provider error); the next trigger retries.
  failed,
}

/// [PushAvailability] plus the provider in use.
@immutable
class PushStatus {
  /// Creates a status.
  const PushStatus(this.availability, {this.provider});

  /// Nothing registered, nothing needed.
  static const PushStatus idle = PushStatus(PushAvailability.idle);

  /// Where alerts stand.
  final PushAvailability availability;

  /// The provider whose token the server holds, when [availability] is
  /// `registered` (or `failed` while one is being released).
  final PushProviderKind? provider;

  @override
  bool operator ==(Object other) =>
      other is PushStatus &&
      other.availability == availability &&
      other.provider == provider;

  @override
  int get hashCode => Object.hash(availability, provider);
}

/// Receives the data of a push that arrived while the app runs.
typedef PushMessageHandler = Future<void> Function(
  PushProviderClient client,
  Map<String, String> data,
);

/// Registers this installation for relative alerts, and only while they are
/// needed (ADR 0008 §1, plan "Push (3.4)"):
///
/// * the [PushNeed] says yes: pick the provider, start it (Firebase and
///   RuStore are initialized here and nowhere else), register its token;
/// * the token changes (provider refresh): register again;
/// * the need ends: delete the token on the server, give it back to the
///   provider, forget the registration;
/// * sign-out: [unregister] does the same while the session still works.
///
/// Reconciling is idempotent and serialized; it never throws and logs nothing
/// (tokens and errors stay out of the logs, `.claude/rules/privacy.md`). A
/// failed step leaves the stored state as it was, so the next trigger (start,
/// resume, a sync, a link change) retries it.
class PushService {
  /// Creates the service. [boundUserId] is the account the local data
  /// belongs to (null: signed out).
  PushService({
    required PushNeed need,
    required PushTokenGateway gateway,
    required PushStateStore state,
    required PushProviderSelector selector,
    required Clock clock,
    required Future<String?> Function() boundUserId,
    required PushMessageHandler onMessage,
  })  : _need = need,
        _gateway = gateway,
        _state = state,
        _selector = selector,
        _clock = clock,
        _boundUserId = boundUserId,
        _onMessage = onMessage;

  final PushNeed _need;
  final PushTokenGateway _gateway;
  final PushStateStore _state;
  final PushProviderSelector _selector;
  final Clock _clock;
  final Future<String?> Function() _boundUserId;
  final PushMessageHandler _onMessage;
  final StreamController<PushStatus> _statuses =
      StreamController<PushStatus>.broadcast();
  PushStatus _status = PushStatus.idle;
  Future<PushStatus>? _running;
  bool _again = false;
  PushProviderClient? _attached;
  StreamSubscription<PushRegistration>? _refreshes;
  StreamSubscription<Map<String, String>>? _messages;

  /// What was registered last, to skip a repeated identical registration
  /// (`user|provider|token`); never stored.
  String? _lastRegistered;

  /// The current status.
  PushStatus get status => _status;

  /// Changes of [status].
  Stream<PushStatus> get statuses => _statuses.stream;

  /// Brings the registration in line with the need. Calls made while a run
  /// is in progress share it and cause one more run afterwards.
  Future<PushStatus> reconcile() {
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    final run = _drain().whenComplete(() => _running = null);
    _running = run;
    return run;
  }

  Future<PushStatus> _drain() async {
    PushStatus result;
    do {
      _again = false;
      result = await _reconcileOnce();
    } while (_again);
    return result;
  }

  Future<PushStatus> _reconcileOnce() async {
    try {
      final user = await _boundUserId();
      if (user == null) {
        return _forgetSession();
      }
      final needed = await _need.isNeeded();
      if (needed == null) {
        return _status;
      }
      final registered = await _state.provider();
      if (!needed) {
        final released = await _release(registered, user);
        return released ? _emit(PushStatus.idle) : _fail();
      }
      final client = await _selector.select();
      if (client == null) {
        final released = await _release(registered, user);
        return released
            ? _emit(const PushStatus(PushAvailability.unavailable))
            : _fail();
      }
      return await _register(client, registered, user);
    } on Object {
      return _fail();
    }
  }

  PushStatus _fail() => _emit(
        PushStatus(PushAvailability.failed, provider: _status.provider),
      );

  /// Signed out: nothing is registered for anyone.
  PushStatus _forgetSession() {
    _detach();
    _lastRegistered = null;
    return _emit(PushStatus.idle);
  }

  Future<PushStatus> _register(
    PushProviderClient client,
    PushProviderKind? registered,
    String user,
  ) async {
    if (registered != null && registered != client.kind) {
      // Another provider than before: the server's row is replaced by the new
      // registration, the old provider just gives its token back.
      await _stopClient(registered);
    }
    final registration = await client.start();
    if (registration == null) {
      return _emit(const PushStatus(PushAvailability.failed));
    }
    final key = '$user|${client.kind.wire}|${registration.token}';
    if (key != _lastRegistered || registered != client.kind) {
      await _gateway.register(
        provider: client.kind,
        registration: registration,
        forUser: user,
      );
      await _state.record(client.kind, _clock());
      _lastRegistered = key;
    }
    _attach(client);
    return _emit(
      PushStatus(PushAvailability.registered, provider: client.kind),
    );
  }

  /// Deletes the registration of [registered] (if any). False when the
  /// server could not be told: the state stays and the next run retries.
  Future<bool> _release(PushProviderKind? registered, String? user) async {
    _detach();
    if (registered == null) {
      return true;
    }
    try {
      await _gateway.unregister(forUser: user);
    } on ApiException {
      return false;
    }
    await _stopClient(registered);
    await _state.clear();
    _lastRegistered = null;
    return true;
  }

  /// Sign-out, while the session still works: the server drops the token,
  /// the provider takes it back, the registration is forgotten. Never throws;
  /// a server that cannot be reached still drops the token with the revoked
  /// refresh token (logout), so the local side is cleaned either way.
  Future<void> unregister() async {
    final running = _running;
    if (running != null) {
      await running;
    }
    try {
      _detach();
      final registered = await _state.provider();
      if (registered == null) {
        return;
      }
      try {
        await _gateway.unregister();
      } on ApiException {
        // The logout that follows revokes the session and the token with it.
      }
      await _stopClient(registered);
      await _state.clear();
      _lastRegistered = null;
      _emit(PushStatus.idle);
    } on Object {
      // Intentionally silent: nothing here may carry a token.
    }
  }

  Future<void> _stopClient(PushProviderKind kind) async {
    try {
      await _selector.clientOf(kind)?.stop();
    } on Object {
      // The provider may be gone (uninstalled RuStore); the server side is
      // what matters.
    }
  }

  void _attach(PushProviderClient client) {
    if (identical(_attached, client)) {
      return;
    }
    _detach();
    _attached = client;
    _refreshes = client.refreshes.listen((_) => unawaited(reconcile()));
    _messages = client.messages.listen(
      (data) => unawaited(_deliver(client, data)),
    );
  }

  void _detach() {
    unawaited(_refreshes?.cancel());
    unawaited(_messages?.cancel());
    _refreshes = null;
    _messages = null;
    _attached = null;
  }

  Future<void> _deliver(
    PushProviderClient client,
    Map<String, String> data,
  ) async {
    try {
      await _onMessage(client, data);
    } on Object {
      // A push that cannot be shown is dropped; nothing is logged.
    }
  }

  PushStatus _emit(PushStatus status) {
    if (status != _status) {
      _status = status;
      if (!_statuses.isClosed) {
        _statuses.add(status);
      }
    }
    return status;
  }

  /// Stops listening; the registration stays.
  Future<void> dispose() async {
    _detach();
    await _statuses.close();
  }
}
