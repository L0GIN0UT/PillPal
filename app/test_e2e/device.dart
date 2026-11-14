import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:http/http.dart' as http;
import 'package:pillpal/src/data/api/api_client.dart';
import 'package:pillpal/src/data/api/auth_api.dart';
import 'package:pillpal/src/data/api/auth_dto.dart';
import 'package:pillpal/src/data/api/consents_api.dart';
import 'package:pillpal/src/data/api/relatives_api.dart';
import 'package:pillpal/src/data/api/sync_api.dart';
import 'package:pillpal/src/data/auth/account_binding.dart';
import 'package:pillpal/src/data/auth/token_store.dart';
import 'package:pillpal/src/data/catalog/catalog_api.dart';
import 'package:pillpal/src/data/clock.dart';
import 'package:pillpal/src/data/config.dart';
import 'package:pillpal/src/data/db/database.dart';
import 'package:pillpal/src/data/db/sync_state_store.dart';
import 'package:pillpal/src/data/repositories/dose_events_repository.dart';
import 'package:pillpal/src/data/repositories/local_writer.dart';
import 'package:pillpal/src/data/repositories/medications_repository.dart';
import 'package:pillpal/src/data/repositories/profiles_repository.dart';
import 'package:pillpal/src/data/repositories/relatives_repository.dart';
import 'package:pillpal/src/data/repositories/schedules_repository.dart';
import 'package:pillpal/src/data/sync/medical_sync_gate.dart';
import 'package:pillpal/src/data/sync/sync_engine.dart';
import 'package:pillpal/src/features/consent/consent_documents.dart';

/// One app installation talking to the real backend and, with [catalogUrl],
/// to the global catalog (milestone 4.12: `catalog_test.dart`).
class Device {
  Device(Uri baseUrl, {Uri? catalogUrl}) : db = _open() {
    syncState = SyncStateStore(db, newUuid);
    final account = AccountBinding(db, syncState);
    tokens = InMemoryTokenStore();
    _baseUrl = baseUrl;
    final serverClock = ServerClock();
    final api = ApiClient(
      httpClient: _http,
      config: ApiConfig(baseUrl: baseUrl, region: 'ru'),
      tokens: tokens,
      deviceId: syncState.deviceId,
      serverClock: serverClock,
      session: account,
    );
    consents = ConsentsApi(api);
    engine = SyncEngine(
      db: db,
      api: SyncApi(api),
      tokens: tokens,
      syncState: syncState,
      // The app's gate: an account without the health data consent does not
      // sync (`consent_gate_test.dart`).
      gate: ConsentSyncGate(syncState: syncState, api: consents),
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
    relatives = RelativesApi(api);
    relativesStore = RelativesRepository(db, syncState);
    medications = MedicationsRepository(
      writer,
      // The tick of the opt-in is accepted only while the server allows it,
      // exactly as the app asks (`medicationsRepositoryProvider`).
      contributionsEnabled: () async =>
          (await relatives.features()).catalogContributionsEnabled,
    );
    catalog = CatalogApi(
      httpClient: _http,
      config: catalogUrl == null
          ? const CatalogConfig.disabled()
          : CatalogConfig(baseUrl: catalogUrl),
      // One random id per installation, as the app's `CatalogInstallId`.
      installId: () async => installId,
    );
    schedules = SchedulesRepository(writer);
    doseEvents = DoseEventsRepository(writer);
  }

  static AppDatabase _open() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    return AppDatabase(NativeDatabase.memory());
  }

  final http.Client _http = http.Client();

  /// The random `X-Catalog-Install` of this installation.
  final String installId = newUuid();
  late final Uri _baseUrl;
  late final InMemoryTokenStore tokens;
  final AppDatabase db;

  /// The address [signUp] registered.
  late final String email;
  late final SyncEngine engine;

  /// The device id, account binding and the stored consent answer.
  late final SyncStateStore syncState;

  /// The consent endpoints, as the app's gate screen uses them.
  late final ConsentsApi consents;

  /// The catalog client; unusable (`StateError`) without a catalog URL.
  late final CatalogApi catalog;
  late final AuthApi auth;
  late final ProfilesRepository profiles;

  /// The relatives endpoints, as the app calls them (invites, the QR panel).
  late final RelativesApi relatives;

  /// The stored links and private notes, as the Family tab keeps them.
  late final RelativesRepository relativesStore;
  late final MedicationsRepository medications;
  late final SchedulesRepository schedules;
  late final DoseEventsRepository doseEvents;

  /// An authenticated raw request, for calls the app has no client for yet
  /// (invites and grants: UI in milestone 3.8). [body] is JSON-encoded.
  Future<http.Response> request(
    String method,
    String path, {
    Map<String, Object?>? body,
  }) async {
    final token = (await tokens.read())!.accessToken;
    final request = http.Request(method, _baseUrl.resolve(path))
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Content-Type'] = 'application/json';
    if (body != null) {
      request.body = jsonEncode(body);
    }
    return http.Response.fromStream(await _http.send(request));
  }

  /// Registers and verifies a new account; returns its user id. The account
  /// accepts the baseline consents of the build's region like the app does
  /// ([withConsents]); a test of a server that does not require them may skip
  /// them. [name] is the person's own name, which sign-up requires.
  Future<String> signUp({
    required String email,
    required String password,
    required String logPath,
    String name = 'E2E User',
    bool withConsents = true,
  }) async {
    this.email = email;
    final known = (await verificationCodes(logPath)).length;
    await auth.register(
      RegisterRequest(
        email: email,
        password: password,
        region: 'ru',
        locale: 'en',
        displayName: name,
        timezone: 'Europe/Samara',
        consents: withConsents ? ConsentDocuments.grantsFor('ru') : null,
      ),
    );
    await auth.verifyEmail(
      email: email,
      code: await latestVerificationCode(logPath, after: known),
    );
    return (await auth.me()).id;
  }

  /// What the consent screen does for an account that lacks consents: records
  /// the baseline texts of the region and stores the server answer.
  Future<void> acceptMissingConsents() async {
    final user = (await auth.me()).id;
    for (final grant in ConsentDocuments.grantsFor('ru')) {
      await consents.accept(grant, userId: user);
    }
    final left = (await consents.get(userId: user)).missing;
    await syncState.saveConsentMissing(user, left);
  }

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

/// The one-time codes of [purpose] the backend logged so far (dev mode,
/// `LOG_EMAIL_CODES=true`; the log never contains the address), oldest first.
Future<List<String>> verificationCodes(
  String logPath, {
  String purpose = 'verify_email',
}) async {
  final codes = <String>[];
  for (final line in await File(logPath).readAsLines()) {
    if (!line.startsWith('{')) {
      continue;
    }
    final Object? json = jsonDecode(line);
    if (json is Map<String, Object?> &&
        json['event'] == 'email_code_sent' &&
        json['purpose'] == purpose &&
        json['dev_code'] is String) {
      codes.add(json['dev_code']! as String);
    }
  }
  return codes;
}

/// The latest code of [purpose]. With [after] (how many codes of that purpose
/// the log held before the request) it waits for the code that request sent:
/// with several accounts the newest code is otherwise a previous one.
Future<String> latestVerificationCode(
  String logPath, {
  int after = 0,
  String purpose = 'verify_email',
}) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    final codes = await verificationCodes(logPath, purpose: purpose);
    if (codes.length > after) {
      return codes.last;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('No $purpose code in the backend log');
}
