import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api/api_exception.dart';
import '../../data/api/consents_dto.dart';
import '../../data/providers.dart';
import '../auth/auth_session.dart';

/// What the server holds of the account's consents (`GET /v1/me/consents`),
/// for the list of «Приватность и данные». Read when the screen opens, never
/// stored: the records are the account's own data.
final consentRecordsProvider = FutureProvider.autoDispose<ConsentsState>((
  ref,
) async {
  final userId = await ref.watch(syncStateStoreProvider).boundUserId();
  if (userId == null) {
    throw const ApiException(ApiException.unauthorized, 401);
  }
  try {
    return await ref.watch(consentsApiProvider).get(userId: userId);
  } on ApiException catch (error) {
    if (error.isUnauthorized) {
      await ref.read(authSessionProvider.notifier).recheck();
    }
    rethrow;
  }
});

/// The active record of [kind]: the newest one that is not withdrawn, or null
/// when it was never given or was withdrawn.
ConsentRecord? activeRecordOf(ConsentsState state, ConsentKind kind) {
  ConsentRecord? newest;
  for (final record in state.records) {
    if (record.kind != kind.wire || record.withdrawnAt != null) {
      continue;
    }
    if (newest == null || record.acceptedAt.isAfter(newest.acceptedAt)) {
      newest = record;
    }
  }
  return newest;
}

/// Withdrawals of the privacy screen.
final privacyActionsProvider = Provider<PrivacyActions>(PrivacyActions.new);

/// What the privacy screen does to the server. Health data, terms and privacy
/// are not here: they are withdrawn by deleting the account (ADR 0016 §4).
class PrivacyActions {
  /// Creates the actions.
  PrivacyActions(this._ref);

  final Ref _ref;

  /// Withdraws the catalog contribution consent; returns how many links to
  /// the catalog the server reset (a replay: 0). Reloads the records and asks
  /// for a sync, so this device pulls the reset links too.
  Future<int> withdrawContribution() async {
    final userId = await _ref.read(syncStateStoreProvider).boundUserId();
    if (userId == null) {
      throw const ApiException(ApiException.unauthorized, 401);
    }
    try {
      final reset = await _ref
          .read(consentsApiProvider)
          .withdraw(ConsentKind.catalogContribution, userId: userId);
      _ref.invalidate(consentRecordsProvider);
      requestSyncFrom(_ref);
      return reset;
    } on ApiException catch (error) {
      if (error.isUnauthorized) {
        await _ref.read(authSessionProvider.notifier).recheck();
      }
      rethrow;
    }
  }
}
