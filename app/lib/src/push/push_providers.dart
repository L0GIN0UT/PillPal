import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../data/providers.dart';
import '../features/auth/auth_session.dart';
import '../features/family/family_providers.dart';
import '../reminders/reminder_content.dart';
import '../routing/router.dart';
import '../settings/app_settings.dart';
import 'alert_local_data.dart';
import 'alert_notification_sink.dart';
import 'alert_platform.dart';
import 'alert_tap_router.dart';
import 'apns_channel.dart';
import 'fcm_client.dart';
import 'push_api.dart';
import 'push_config.dart';
import 'push_need_provider.dart';
import 'push_payload.dart';
import 'push_provider_client.dart';
import 'push_service.dart';
import 'push_state_store.dart';
import 'relatives_alert_notifier.dart';
import 'resolved_alerts.dart';
import 'rustore_client.dart';

// Push wiring (milestone 3.9). Tests override [pushConfigProvider],
// [pushSelectorProvider] (fake clients) and the data-layer providers.

/// Which providers this build has settings for (`--dart-define`s).
final pushConfigProvider = Provider<PushConfig>(
  (ref) => PushConfig.fromEnvironment(
    region: ref.watch(apiConfigProvider).region,
  ),
);

/// What this installation registered.
final pushStateStoreProvider = Provider<PushStateStore>(
  (ref) => PushStateStore(ref.watch(databaseProvider)),
);

/// The token endpoints.
final pushGatewayProvider = Provider<PushTokenGateway>(
  (ref) => PushApi(ref.watch(apiClientProvider)),
);

/// The native alerts channel (Android): posts the notifications and reports
/// taps. Created on first use, in the platforms that have it.
final alertPlatformProvider = Provider<AlertPlatform>((ref) => AlertPlatform());

/// Which alerts were resolved already (a late `missed` is not shown).
final resolvedAlertsProvider = Provider<ResolvedAlerts>(
  (ref) => FileResolvedAlerts(
    directory: getApplicationSupportDirectory,
    clock: ref.watch(clockProvider),
  ),
);

/// The iOS client, which owns the native channel's handler.
final apnsChannelProvider = Provider<ApnsChannel>((ref) => ApnsChannel());

/// Picks the provider of this device. Clients that cannot exist on this
/// platform are not created.
final pushSelectorProvider = Provider<PushProviderSelector>((ref) {
  final config = ref.watch(pushConfigProvider);
  return switch (defaultTargetPlatform) {
    TargetPlatform.iOS => PushProviderSelector(
        platform: TargetPlatform.iOS,
        apns: ref.watch(apnsChannelProvider),
      ),
    TargetPlatform.android => PushProviderSelector(
        platform: TargetPlatform.android,
        fcm: FcmClient(options: config.fcm),
        rustore: RuStoreClient(projectId: config.rustoreProjectId),
      ),
    _ => PushProviderSelector(platform: defaultTargetPlatform),
  };
});

/// Locale of the notifications of this app (the app's, else the system's).
Locale _notificationLocale(Ref<Object?> ref) =>
    ref.read(settingsProvider).locale ?? PlatformDispatcher.instance.locale;

/// Registers this installation while alerts are needed.
final pushServiceProvider = Provider<PushService>((ref) {
  final service = PushService(
    need: ref.watch(pushNeedProvider),
    gateway: ref.watch(pushGatewayProvider),
    state: ref.watch(pushStateStoreProvider),
    selector: ref.watch(pushSelectorProvider),
    clock: ref.watch(clockProvider),
    boundUserId: ref.watch(syncStateStoreProvider).boundUserId,
    hasSession: () async => await ref.read(tokenStoreProvider).read() != null,
    onMessage: (client, data) => _showInForeground(ref, client, data),
  );
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

/// A push while the app runs: FCM and RuStore deliver data only, so the app
/// draws the notification itself from local data; APNs alerts are drawn by the
/// system. Either way the data behind it is refreshed, so the relative's day
/// is current when it is opened.
Future<void> _showInForeground(
  Ref<Object?> ref,
  PushProviderClient client,
  Map<String, String> data,
) async {
  final payload = PushPayload.tryParse(data);
  if (payload == null) {
    return;
  }
  if (client.rendersLocally) {
    final strings = reminderStrings(_notificationLocale(ref));
    await RelativesAlertNotifier(
      data: DriftAlertLocalData(ref.read(databaseProvider)),
      sink: PlatformAlertNotificationSink(
        strings,
        ref.read(alertPlatformProvider),
      ),
      resolved: ref.read(resolvedAlertsProvider),
      strings: strings,
    ).handle(payload);
  }
  requestSyncFrom(ref);
  if (!payload.kind.isDoseAlert) {
    await ref.read(familyActionsProvider).refresh();
  }
}

/// Mirrors [PushService.statuses].
class PushStatusNotifier extends Notifier<PushStatus> {
  @override
  PushStatus build() {
    final service = ref.watch(pushServiceProvider);
    final subscription = service.statuses.listen((status) => state = status);
    ref.onDispose(() => unawaited(subscription.cancel()));
    return service.status;
  }
}

/// Where relative alerts stand on this device.
final pushStatusProvider = NotifierProvider<PushStatusNotifier, PushStatus>(
  PushStatusNotifier.new,
);

/// Opens the destination of a tapped alert.
final alertTapRouterProvider = Provider<AlertTapRouter>((ref) {
  final db = ref.watch(databaseProvider);
  final router = ref.watch(routerProvider);
  return AlertTapRouter(
    isSignedIn: () => ref.read(authSessionProvider).valueOrNull ?? false,
    knowsProfile: (profileId) async {
      final rows = await db.select(db.accessScopes).get();
      return rows.any((row) => row.profileId == profileId && !row.archived);
    },
    push: (location) => unawaited(router.push<void>(location)),
    go: router.go,
    refresh: () async {
      requestSyncFrom(ref);
      await ref.read(familyActionsProvider).refresh();
    },
  );
});

/// Overrides `main.dart` installs: the push token is deleted at sign-out.
final List<Override> pushAppOverrides = [
  beforeLogoutProvider.overrideWith(
    (ref) => ref.watch(pushServiceProvider).unregister,
  ),
];
