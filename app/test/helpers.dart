import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show DatabaseConnection, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pillpal/src/app.dart';
import 'package:pillpal/src/data/api/auth_dto.dart';
import 'package:pillpal/src/data/auth/token_store.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/providers.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/features/auth/auth_session.dart';
import 'package:pillpal/src/features/common/local_time.dart';
import 'package:pillpal/src/home_widget/home_widget_updater.dart';
import 'package:pillpal/src/reminders/providers.dart';
import 'package:pillpal/src/routing/router.dart';
import 'package:pillpal/src/settings/app_settings.dart';

import 'home_widget/fake_home_widget_channel.dart';
import 'reminders/reminder_test_env.dart';

/// Synthetic test zone: UTC+4 all year (no DST).
const String testZone = 'Europe/Samara';

/// 2026-10-16 (Friday) 10:00 in [testZone].
final DateTime testNow = DateTime.utc(2026, 10, 16, 6);

/// An unsigned JWT with the claims the client reads (`sub`, `region`).
String fakeAccessToken({String userId = 'user-1', String region = 'ru'}) {
  String part(Map<String, Object?> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${part({'alg': 'none'})}.'
      '${part({'sub': userId, 'region': region})}.signature';
}

/// Id of the seeded self profile.
const String selfProfileId = '00000000-0000-4000-8000-000000000001';

/// In-memory app environment: drift DB, token store, fake HTTP, fixed clock
/// and zone, and a counting sync trigger instead of real sync runs.
class TestHarness {
  /// Creates a harness; [handler] answers HTTP (default: 503).
  TestHarness({
    bool signedIn = true,
    Future<http.Response> Function(http.Request request)? handler,
    DateTime? now,
    this.zone = testZone,
  })  : db = _openDatabase(),
        now = now ?? testNow,
        tokens = InMemoryTokenStore(
          signedIn
              ? TokenPair(
                  accessToken: fakeAccessToken(),
                  refreshToken: 'refresh',
                  accessExpiresAt: DateTime.utc(2100),
                )
              : null,
        ),
        httpClient = MockClient(
          handler ?? (request) async => http.Response('', 503),
        );

  static AppDatabase _openDatabase() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    // Streams close at once when their last listener goes (an auto-disposed
    // provider), instead of on a zero-delay timer that would still be
    // pending when a widget test ends.
    return AppDatabase(
      DatabaseConnection(
        NativeDatabase.memory(),
        closeStreamsSynchronously: true,
      ),
    );
  }

  /// The local database.
  final AppDatabase db;

  /// Session tokens.
  final InMemoryTokenStore tokens;

  /// Fake HTTP client.
  final http.Client httpClient;

  /// Current instant returned by the clock.
  DateTime now;

  /// IANA zone the platform reports for the device.
  final String zone;

  /// How many times a sync was requested.
  int syncCalls = 0;

  /// Provider overrides for the app.
  List<Override> get overrides => [
        databaseProvider.overrideWithValue(db),
        tokenStoreProvider.overrideWithValue(tokens),
        httpClientProvider.overrideWithValue(httpClient),
        clockProvider.overrideWithValue(() => now),
        timeZoneReaderProvider.overrideWithValue(() async => zone),
        deviceTimeZoneProvider.overrideWithValue(zone),
        syncTriggerProvider.overrideWithValue(() async {
          syncCalls++;
        }),
        // Reminders (2.3) without the notification plugin.
        notificationSchedulerProvider.overrideWithValue(
          FakeNotificationScheduler(() => now),
        ),
        reminderPermissionActionsProvider.overrideWithValue(
          const _NoPermissionRequests(),
        ),
        batteryHintVendorProvider.overrideWith((ref) async => null),
        // No home-screen widget platform in widget tests.
        homeWidgetChannelProvider.overrideWithValue(
          FakeHomeWidgetChannel(supported: false),
        ),
      ];

  /// Inserts the `self` profile (normally delivered by the first pull).
  Future<void> seedSelfProfile() async {
    await db.into(db.profiles).insert(
          const ProfileRow(
            id: selfProfileId,
            kind: 'self',
            displayName: 'Test User',
            timezone: testZone,
            clientUpdatedAt: 1,
            updatedByDevice: 'test-device',
          ),
        );
  }

  /// Creates a medication of the self profile; returns its id.
  Future<String> seedMedication(
    ProviderContainer container, {
    String name = 'Med A',
    String? strength,
    String? stockCount,
    String? stockUnit,
    String privacy = 'shared',
  }) {
    return container.read(medicationsRepositoryProvider).create(
          profileId: selfProfileId,
          draft: MedicationDraft(
            name: name,
            strengthText: strength,
            stockCount: stockCount,
            stockUnit: stockUnit,
            privacy: privacy,
          ),
        );
  }

  /// Creates a schedule; returns its id.
  Future<String> seedSchedule(
    ProviderContainer container,
    String medicationId,
    Map<String, Object?> rule,
  ) {
    return container
        .read(schedulesRepositoryProvider)
        .create(medicationId: medicationId, rule: rule);
  }
}

/// Permission requests that grant nothing (no platform in widget tests).
class _NoPermissionRequests implements ReminderPermissionActions {
  const _NoPermissionRequests();

  @override
  Future<bool> requestNotifications() async => false;

  @override
  Future<bool> requestExactAlarms() async => false;

  @override
  Future<bool> openBatterySettings() async => false;

  @override
  Future<bool> openNotificationSettings() async => false;
}

/// A rule document for tests (docs/spec/schedule.md §1).
Map<String, Object?> testRule({
  String kind = 'daily',
  List<String> times = const ['08:00'],
  String amount = '1',
  String startDate = '2026-10-01',
}) =>
    {
      'v': 1,
      'kind': kind,
      'start_date': startDate,
      'end_date': null,
      'times': [
        for (final time in times)
          {
            'time': time,
            'dose': {'amount': amount, 'unit': 'tablet'},
          },
      ],
    };

/// A phone-width surface tall enough to build whole screens.
void useTallPhoneSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(390 * 3, 2400 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

/// Creates the container for [harness] (disposed with the test), with
/// [overrides] on top of the harness's own.
ProviderContainer createContainer(
  TestHarness harness, {
  List<Override> overrides = const [],
}) {
  final container = ProviderContainer(
    overrides: [...harness.overrides, ...overrides],
  );
  addTearDown(() {
    container.dispose();
    // Not awaited: drift's close waits for stream-cache timers created in the
    // widget test's fake-async zone, which no longer advances here.
    unawaited(harness.db.close());
  });
  return container;
}

/// Pumps the whole app and settles; returns its container.
Future<ProviderContainer> pumpApp(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  TestHarness? harness,
  ProviderContainer? container,
  void Function(ProviderContainer container)? configure,
}) async {
  useTallPhoneSurface(tester);
  final env = harness ?? TestHarness();
  final scope = container ?? createContainer(env);
  scope.read(settingsProvider.notifier).setLocale(locale);
  configure?.call(scope);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: scope, child: const PillPalApp()),
  );
  await tester.pumpAndSettle();
  return scope;
}

/// Pushes [location] on the app router (pump afterwards).
void openRoute(ProviderContainer container, String location) {
  unawaited(container.read(routerProvider).push<void>(location));
}

/// Navigates the app router to [location] (replacing the stack).
void goRoute(ProviderContainer container, String location) {
  container.read(routerProvider).go(location);
}
