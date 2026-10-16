import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:http/http.dart' as http;
import 'package:pillpal/src/data/api/api_client.dart';
import 'package:pillpal/src/data/api/auth_api.dart';
import 'package:pillpal/src/data/api/sync_api.dart';
import 'package:pillpal/src/data/auth/account_binding.dart';
import 'package:pillpal/src/data/auth/token_store.dart';
import 'package:pillpal/src/data/clock.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/db/sync_state_store.dart';
import 'package:pillpal/src/data/repositories/dose_events_repository.dart';
import 'package:pillpal/src/data/repositories/local_writer.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/data/repositories/profiles_repository.dart';
import 'package:pillpal/src/data/repositories/schedules_repository.dart';
import 'package:pillpal/src/data/sync/sync_engine.dart';

/// One app installation talking to the real backend.
class Device {
  Device(Uri baseUrl) : db = _open() {
    final syncState = SyncStateStore(db, newUuid);
    final account = AccountBinding(db, syncState);
    final tokens = InMemoryTokenStore();
    final serverClock = ServerClock();
    final api = ApiClient(
      httpClient: _http,
      config: ApiConfig(baseUrl: baseUrl, region: 'ru'),
      tokens: tokens,
      deviceId: syncState.deviceId,
      serverClock: serverClock,
      session: account,
    );
    engine = SyncEngine(
      db: db,
      api: SyncApi(api),
      tokens: tokens,
      syncState: syncState,
      serverClock: serverClock,
    );
    auth = AuthApi(api, tokens, flush: engine.flush);
    final writer = LocalWriter(
      db: db,
      syncState: syncState,
      clock: serverClock.now,
      newId: newUuid,
    );
    profiles = ProfilesRepository(writer);
    medications = MedicationsRepository(writer);
    schedules = SchedulesRepository(writer);
    doseEvents = DoseEventsRepository(writer);
  }

  static AppDatabase _open() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    return AppDatabase(NativeDatabase.memory());
  }

  final http.Client _http = http.Client();
  final AppDatabase db;
  late final SyncEngine engine;
  late final AuthApi auth;
  late final ProfilesRepository profiles;
  late final MedicationsRepository medications;
  late final SchedulesRepository schedules;
  late final DoseEventsRepository doseEvents;

  /// Syncs and fails the test on any sync error.
  Future<void> sync() async {
    final report = await engine.sync();
    if (!report.ok || report.parked > 0) {
      throw StateError(
        'sync failed: ${report.errorCode}, parked ${report.parked}',
      );
    }
  }

  /// Live rows of every entity, comparable across devices.
  Future<Map<String, List<String>>> snapshot() async {
    String row(Map<String, Object?> json) => jsonEncode(json);
    return {
      'profiles': [
        for (final p in await db.select(db.profiles).get())
          if (p.deletedAt == null)
            row({'id': p.id, 'name': p.displayName, 'tz': p.timezone}),
      ]..sort(),
      'medications': [
        for (final m in await db.select(db.medications).get())
          if (m.deletedAt == null)
            row({
              'id': m.id,
              'profile': m.profileId,
              'name': m.name,
              'notes': m.notes,
              'stock': m.stockCount,
              'privacy': m.privacy,
            }),
      ]..sort(),
      'schedules': [
        for (final s in await db.select(db.schedules).get())
          if (s.deletedAt == null)
            row({'id': s.id, 'rule': s.scheduleRule.toJson()}),
      ]..sort(),
      'dose_events': [
        for (final e in await db.select(db.doseEvents).get())
          row({'id': e.id, 'type': e.eventType, 'at': e.at}),
      ]..sort(),
    };
  }

  Future<void> close() async {
    await engine.dispose();
    await db.close();
    _http.close();
  }
}

/// The latest e-mail verification code the backend logged (dev mode,
/// `LOG_EMAIL_CODES=true`; the log never contains the address).
Future<String> latestVerificationCode(String logPath) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    String? code;
    for (final line in await File(logPath).readAsLines()) {
      if (!line.startsWith('{')) {
        continue;
      }
      final Object? json = jsonDecode(line);
      if (json is Map<String, Object?> &&
          json['event'] == 'email_code_sent' &&
          json['purpose'] == 'verify_email' &&
          json['dev_code'] is String) {
        code = json['dev_code']! as String;
      }
    }
    if (code != null) {
      return code;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('No verification code in the backend log');
}
