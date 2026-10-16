import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/providers.dart';

/// Data region of an account (TZ §1): RU (152-FZ) or EU (GDPR).
enum DataRegion {
  /// Russia: data stays in the RU deployment.
  ru('ru'),

  /// Europe and the rest of the world.
  eu('eu');

  const DataRegion(this.wire);

  /// Wire value of `RegisterRequest.region`.
  final String wire;

  /// The region with wire value [wire]; RU for anything unknown.
  static DataRegion fromWire(String wire) =>
      wire == DataRegion.eu.wire ? DataRegion.eu : DataRegion.ru;

  /// The region suggested for a device [locale]: Russian -> RU, else EU.
  ///
  /// Until Phase 5 (regional routing) a build serves exactly one region
  /// (`PILLPAL_REGION`); the suggestion only decides whether the welcome
  /// screen explains that the other region comes later (TZ §1, §5).
  static DataRegion suggestedFor(Locale locale) =>
      locale.languageCode == 'ru' ? DataRegion.ru : DataRegion.eu;
}

/// Whether a session is stored. `AsyncLoading` while the keystore is read.
final authSessionProvider = AsyncNotifierProvider<AuthSession, bool>(
  AuthSession.new,
);

/// The signed-in state that gates the router.
class AuthSession extends AsyncNotifier<bool> {
  @override
  Future<bool> build() => ref.watch(authApiProvider).isSignedIn();

  /// Called after verify-email or login stored the tokens.
  void markSignedIn() {
    state = const AsyncData(true);
  }

  /// Re-reads the token store (the API client clears it when the session is
  /// revoked).
  Future<void> recheck() async {
    final signedIn = await ref.read(authApiProvider).isSignedIn();
    if (state.valueOrNull != signedIn) {
      state = AsyncData(signedIn);
    }
  }

  /// Signs out: [AuthApi.logout] pushes pending changes (best effort),
  /// revokes the session and erases this account's local data. Only after it
  /// completed does the router leave the app for onboarding.
  Future<void> signOut() async {
    await ref.read(authApiProvider).logout();
    state = const AsyncData(false);
  }
}

/// Whether this device holds data bound to an account while signed out.
///
/// A forced sign-out (revoked refresh token) keeps the data and its binding
/// so the same account can sign in again and push its outbox; signing in as
/// another account erases it (see `AccountBinding`).
final hasBoundLocalDataProvider = FutureProvider<bool>((ref) async {
  final signedIn = ref.watch(authSessionProvider).valueOrNull ?? false;
  if (signedIn) {
    return false;
  }
  return await ref.read(syncStateStoreProvider).boundUserId() != null;
});

/// Runs one sync; screens call it on open, pull-to-refresh and after writes.
typedef SyncTrigger = Future<void> Function();

/// Starts a sync and signs out locally if the server revoked the session.
final syncTriggerProvider = Provider<SyncTrigger>((ref) {
  return () async {
    final report = await ref.read(syncEngineProvider).sync();
    if (report.signedOut || !report.ok) {
      await ref.read(authSessionProvider.notifier).recheck();
    }
  };
});

/// Fire-and-forget [SyncTrigger] call for UI callbacks.
void requestSync(WidgetRef ref) {
  unawaited(ref.read(syncTriggerProvider)());
}

/// Fire-and-forget [SyncTrigger] call from a provider or notifier.
void requestSyncFrom(Ref<Object?> ref) {
  unawaited(ref.read(syncTriggerProvider)());
}
