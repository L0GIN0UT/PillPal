import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_exception.dart';
import '../../data/api/consents_dto.dart';
import '../../data/db/sync_state_store.dart';
import '../../data/providers.dart';
import '../auth/auth_flow_state.dart';
import '../auth/auth_session.dart';
import 'consent_documents.dart';

/// The consent kinds (wire values) the server still wants; null while that is
/// not known. Follows the stored answer, so the router, the gate screen and
/// the sync engine agree.
final consentMissingProvider = StreamProvider<List<String>?>(
  (ref) => ref.watch(syncStateStoreProvider).watchConsentMissing(),
);

/// Whether the blocking consent screen is due: the server lacks a consent
/// (any kind) of the signed-in account.
final consentRequiredProvider = Provider<bool>((ref) {
  final missing = ref.watch(consentMissingProvider).valueOrNull;
  return missing != null && missing.isNotEmpty;
});

/// Whether the consent answer of the signed-in account is not known yet: the
/// stored one is still being read, or none is stored and the server is being
/// asked. Offline with no stored answer is not pending: the app must stay
/// usable (reminders, local data), so it carries on until the next check.
final consentPendingProvider = Provider<bool>((ref) {
  final missing = ref.watch(consentMissingProvider);
  if (missing.isLoading && !missing.hasValue) {
    return true;
  }
  return missing.valueOrNull == null &&
      ref.watch(consentGateProvider.select((state) => state.checking));
});

/// Whether the medical sync is paused because health data lacks its consent
/// (never recorded or withdrawn; an outdated version alone does not pause).
final medicalSyncPausedProvider = Provider<bool>((ref) {
  final missing = ref.watch(consentMissingProvider).valueOrNull;
  return missing != null && StoredConsents.pausesSync(missing);
});

/// State of the consent screen.
@immutable
class ConsentGateState {
  /// Creates a state.
  const ConsentGateState({
    this.busy = false,
    this.errorCode,
    this.outdated = false,
    this.checking = false,
    this.retryUntil,
  });

  /// Consents are being sent.
  final bool busy;

  /// Error of the last action (server code or [AuthClientErrors] code).
  final String? errorCode;

  /// The server asks for versions this app does not know: it must be updated
  /// before the consents can be given. The exits of the screen stay.
  final bool outdated;

  /// The server is being asked which consents are missing (start, resume,
  /// sign-in). While the answer is unknown the router holds the loading
  /// screen instead of letting a screen through for a frame.
  final bool checking;

  /// After a `429` the consents are not sent before this instant.
  final DateTime? retryUntil;

  /// Copy with the given fields replaced; [errorCode] is cleared unless
  /// given, [retryUntil] is kept unless given or [clearRetryUntil].
  ConsentGateState copyWith({
    bool? busy,
    String? errorCode,
    bool? outdated,
    bool? checking,
    DateTime? retryUntil,
    bool clearRetryUntil = false,
  }) {
    return ConsentGateState(
      busy: busy ?? this.busy,
      errorCode: errorCode,
      outdated: outdated ?? this.outdated,
      checking: checking ?? this.checking,
      retryUntil: clearRetryUntil ? null : retryUntil ?? this.retryUntil,
    );
  }
}

/// The consent gate: asks the server which consents are missing and records
/// the ones the user gives (ADR 0016 §5).
final consentGateProvider =
    NotifierProvider<ConsentGateController, ConsentGateState>(
  ConsentGateController.new,
);

/// Drives the consent screen and keeps the stored "missing" answer fresh. The
/// answer decides whether the medical sync runs; it is written only while the
/// data is bound to the account that asked.
class ConsentGateController extends Notifier<ConsentGateState> {
  /// How long the consents wait after a `429` without `Retry-After`.
  static const Duration defaultRetryDelay = Duration(seconds: 30);

  /// The longest wait a server may ask for.
  static const Duration maxRetryDelay = Duration(minutes: 10);

  /// Bumped when an [accept] starts and ends: an answer of a [refresh] that
  /// began earlier may be older than what was just recorded and is dropped.
  int _generation = 0;
  Timer? _retryTimer;

  /// The order the texts are recorded in: the one that lifts the sync pause
  /// goes first, so a failure further down does not keep the sync paused.
  static final List<ConsentKind> _recordOrder = [
    ConsentKind.healthData,
    for (final kind in ConsentKind.baseline)
      if (kind != ConsentKind.healthData) kind,
  ];

  @override
  ConsentGateState build() {
    ref.onDispose(() => _retryTimer?.cancel());
    return const ConsentGateState();
  }

  /// Marks the answer as being asked for (a sign-in, before the router sees
  /// the session), so no screen shows for a frame before the gate.
  void expectAnswer() {
    state = state.copyWith(checking: true, errorCode: state.errorCode);
  }

  bool get _signedIn => ref.read(authSessionProvider).valueOrNull ?? false;

  /// Asks the server which consents are missing and stores the answer
  /// (app start, resume). Offline or refused: the stored answer stays. When
  /// the health-data consent turns out to be there, the paused sync resumes.
  Future<void> refresh() async {
    state = state.copyWith(checking: true, errorCode: state.errorCode);
    final generation = _generation;
    try {
      await _refresh(generation);
    } finally {
      state = state.copyWith(checking: false, errorCode: state.errorCode);
    }
  }

  Future<void> _refresh(int generation) async {
    final userId = await ref.read(syncStateStoreProvider).boundUserId();
    if (userId == null || !_signedIn) {
      return;
    }
    try {
      await _fetchAndStore(userId, generation: generation);
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        await ref.read(authSessionProvider.notifier).recheck();
      }
    } on FormatException {
      // An answer the app cannot read changes nothing; the stored one stays.
    }
  }

  /// Records [kinds] (the ticked texts, in the order of the screen), one
  /// request after another. True when every one was recorded. On a failure
  /// the kinds that did get recorded are removed from the stored list, so
  /// the screen retries only the rest.
  Future<bool> accept(Set<ConsentKind> kinds) async {
    if (state.busy || _waitingToRetry()) {
      return false;
    }
    final store = ref.read(syncStateStoreProvider);
    final userId = await store.boundUserId();
    final documents = _documentsOf(ref.read(apiConfigProvider).region);
    if (userId == null || !_signedIn || documents == null) {
      state = state.copyWith(errorCode: AuthClientErrors.generic);
      return false;
    }
    state = state.copyWith(busy: true);
    _generation++;
    try {
      return await _accept(store, userId, documents, kinds);
    } finally {
      _generation++;
    }
  }

  bool _waitingToRetry() {
    final until = state.retryUntil;
    return until != null && until.isAfter(ref.read(clockProvider)());
  }

  Future<bool> _accept(
    SyncStateStore store,
    String userId,
    Map<ConsentKind, ConsentDocument> documents,
    Set<ConsentKind> kinds,
  ) async {
    final accepted = <ConsentKind>{};
    try {
      for (final kind in _recordOrder.where(kinds.contains)) {
        final document = documents[kind];
        if (document == null) {
          continue;
        }
        await ref.read(consentsApiProvider).accept(
              ConsentGrant(kind: kind, version: document.version),
              userId: userId,
            );
        accepted.add(kind);
      }
    } on ApiException catch (error) {
      await _stand(userId, accepted);
      await _failed(userId, error);
      return false;
    } on FormatException {
      await _stand(userId, accepted);
      state = state.copyWith(
        busy: false,
        errorCode: ApiException.invalidResponse,
      );
      return false;
    }
    await _confirm(userId, accepted);
    state = state.copyWith(busy: false);
    return true;
  }

  /// After the last record: the server's own list decides. If it cannot be
  /// read, the stored list minus what was just recorded stands in, so the
  /// user is not asked again for what they gave.
  Future<void> _confirm(String userId, Set<ConsentKind> accepted) async {
    try {
      await _fetchAndStore(userId);
    } on ApiException {
      await _stand(userId, accepted);
    } on FormatException {
      await _stand(userId, accepted);
    }
  }

  /// The server list could not be had: the stored one minus what was just
  /// recorded stands in, and the sync resumes if that opens the gate.
  Future<void> _stand(String userId, Set<ConsentKind> accepted) async {
    await _forgetAccepted(userId, accepted);
    _resumeIfOpen(await ref.read(syncStateStoreProvider).consentMissing());
  }

  Future<void> _failed(String userId, ApiException error) async {
    if (error.isUnauthorized) {
      state = state.copyWith(busy: false, errorCode: error.code);
      await ref.read(authSessionProvider.notifier).recheck();
      return;
    }
    if (ConsentErrors.isRefusal(error.code)) {
      // The version moved on: learn the server's, then say so.
      try {
        await _fetchAndStore(userId);
      } on ApiException {
        // The answer stays as it was; the message is the same.
      } on FormatException {
        // Likewise.
      }
      state = state.copyWith(
        busy: false,
        errorCode: AuthClientErrors.consentOutdated,
        outdated: true,
      );
      return;
    }
    if (error.status == 429 || error.code == ApiException.rateLimited) {
      _waitBeforeRetry(error.retryAfter ?? defaultRetryDelay);
      return;
    }
    state = state.copyWith(busy: false, errorCode: error.code);
  }

  /// The consents are not sent again before [delay] has passed; the screen
  /// follows [ConsentGateState.retryUntil].
  void _waitBeforeRetry(Duration delay) {
    final wait = delay > maxRetryDelay ? maxRetryDelay : delay;
    state = state.copyWith(
      busy: false,
      errorCode: ApiException.rateLimited,
      retryUntil: ref.read(clockProvider)().add(wait),
    );
    _retryTimer?.cancel();
    _retryTimer = Timer(
      wait,
      () => state = state.copyWith(
        errorCode: state.errorCode,
        clearRetryUntil: true,
      ),
    );
  }

  Future<void> _fetchAndStore(String userId, {int? generation}) async {
    final store = ref.read(syncStateStoreProvider);
    final before = await store.consentMissing();
    final wasPaused = before != null && StoredConsents.pausesSync(before);
    final server = await ref.read(consentsApiProvider).get(userId: userId);
    if (generation != null && generation != _generation) {
      // Consents were recorded meanwhile: this answer may predate them.
      return;
    }
    final stored = server.storedMissing;
    if (!await store.saveConsentMissing(userId, stored)) {
      return;
    }
    final outdated = _isOutdated(server);
    state = state.copyWith(
      // "Update the app" goes away once the versions meet again.
      errorCode:
          !outdated && state.errorCode == AuthClientErrors.consentOutdated
              ? null
              : state.errorCode,
      outdated: outdated,
    );
    if (wasPaused) {
      _resumeIfOpen(stored);
    }
  }

  Future<void> _forgetAccepted(String userId, Set<ConsentKind> accepted) async {
    if (accepted.isEmpty) {
      return;
    }
    final store = ref.read(syncStateStoreProvider);
    final stored = await store.consentMissing();
    if (stored == null) {
      return;
    }
    final wires = {for (final kind in accepted) kind.wire};
    await store.saveConsentMissing(userId, [
      for (final item in stored)
        if (!wires.contains(StoredConsents.kindOf(item))) item,
    ]);
  }

  /// The paused rows go as soon as the gate is open.
  void _resumeIfOpen(List<String>? missing) {
    if (missing != null && !StoredConsents.pausesSync(missing)) {
      // A run that already decided to pause must not swallow this request.
      ref.read(syncEngineProvider).rerunAfterCurrent();
      requestSyncFrom(ref);
    }
  }

  /// A missing kind the app has no text for, or one whose version differs
  /// from the text the app shows: only an update helps.
  bool _isOutdated(ConsentsState server) {
    final documents = _documentsOf(ref.read(apiConfigProvider).region);
    if (documents == null) {
      return false;
    }
    for (final wire in server.missing) {
      final kind = ConsentKind.tryParse(wire);
      final document = kind == null ? null : documents[kind];
      if (document == null || server.current[wire] != document.version) {
        return true;
      }
    }
    return false;
  }

  Map<ConsentKind, ConsentDocument>? _documentsOf(String region) {
    try {
      return ConsentDocuments.forRegion(region);
    } on UnknownConsentRegion {
      return null;
    }
  }
}
