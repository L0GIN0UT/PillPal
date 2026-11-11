import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_exception.dart';
import '../../data/api/consents_dto.dart';
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

/// Whether the medical sync is paused because health data lacks its consent.
final medicalSyncPausedProvider = Provider<bool>((ref) {
  final missing = ref.watch(consentMissingProvider).valueOrNull;
  return missing != null && missing.contains(ConsentKind.healthData.wire);
});

/// State of the consent screen.
@immutable
class ConsentGateState {
  /// Creates a state.
  const ConsentGateState({
    this.busy = false,
    this.errorCode,
    this.outdated = false,
  });

  /// Consents are being sent.
  final bool busy;

  /// Error of the last action (server code or [AuthClientErrors] code).
  final String? errorCode;

  /// The server asks for versions this app does not know: it must be updated
  /// before the consents can be given. The exits of the screen stay.
  final bool outdated;

  /// Copy with [busy] and [outdated] replaced if given; [errorCode] is
  /// cleared unless given.
  ConsentGateState copyWith({bool? busy, String? errorCode, bool? outdated}) {
    return ConsentGateState(
      busy: busy ?? this.busy,
      errorCode: errorCode,
      outdated: outdated ?? this.outdated,
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
  @override
  ConsentGateState build() => const ConsentGateState();

  bool get _signedIn => ref.read(authSessionProvider).valueOrNull ?? false;

  /// Asks the server which consents are missing and stores the answer
  /// (app start, resume). Offline or refused: the stored answer stays. When
  /// the health-data consent turns out to be there, the paused sync resumes.
  Future<void> refresh() async {
    final userId = await ref.read(syncStateStoreProvider).boundUserId();
    if (userId == null || !_signedIn) {
      return;
    }
    try {
      await _fetchAndStore(userId);
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
    final store = ref.read(syncStateStoreProvider);
    final userId = await store.boundUserId();
    final documents = _documentsOf(ref.read(apiConfigProvider).region);
    if (state.busy || userId == null || !_signedIn || documents == null) {
      state = state.copyWith(errorCode: AuthClientErrors.generic);
      return false;
    }
    state = state.copyWith(busy: true);
    final accepted = <ConsentKind>{};
    try {
      for (final kind in ConsentKind.baseline.where(kinds.contains)) {
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
      await _forgetAccepted(userId, accepted);
      await _failed(userId, error);
      return false;
    } on FormatException {
      await _forgetAccepted(userId, accepted);
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
    state = state.copyWith(busy: false, errorCode: error.code);
  }

  Future<void> _fetchAndStore(String userId) async {
    final store = ref.read(syncStateStoreProvider);
    final wasPaused =
        (await store.consentMissing())?.contains(ConsentKind.healthData.wire) ??
            false;
    final server = await ref.read(consentsApiProvider).get(userId: userId);
    if (!await store.saveConsentMissing(userId, server.missing)) {
      return;
    }
    state = ConsentGateState(
      busy: state.busy,
      errorCode: state.errorCode,
      outdated: _isOutdated(server),
    );
    if (wasPaused) {
      _resumeIfOpen(server.missing);
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
      for (final wire in stored)
        if (!wires.contains(wire)) wire,
    ]);
  }

  /// The paused rows go as soon as the gate is open.
  void _resumeIfOpen(List<String>? missing) {
    if (missing != null && !missing.contains(ConsentKind.healthData.wire)) {
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
