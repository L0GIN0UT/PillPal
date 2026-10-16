---
name: flutter-patterns
description: Use this skill when writing Dart for PillPal - the pure-Dart pillpal_core package (models, schedule engine) and, from Phase 2, the Flutter app with Riverpod, drift, flutter_local_notifications, l10n (RU/EN), accessibility (elderly mode) and offline-first sync.
---

# Flutter / Dart patterns

## pillpal_core (Phase 1)
- Pure Dart (`dart test`), no Flutter, no IO. Public API exported from `lib/pillpal_core.dart`; internals in `lib/src/`.
- Engine API takes everything as input: rule, schedule id, window, zone (`timezone` package `Location`).
  No `DateTime.now()` inside the engine.
- Immutable value types with `==`/`hashCode`; JSON (de)serialization mirrors the backend schema exactly.
- Vector runner reads `../../spec/schedule-vectors/*.json` and must run **all** of them.

## App structure (Phase 2)
```
app/lib/
  main.dart                 ProviderScope + bootstrap (tz init, drift open, notification init)
  core/                     theme (light/dark/elderly), l10n, router (go_router), env/region
  data/                     drift database, DAOs, sync client (outbox + pull), api client
  features/<feature>/       today/, medication/, schedule/, history/, relatives/ — providers + widgets
  notifications/            ReminderPlanner (pure) + platform adapter
```
- **Riverpod**: providers for repositories/services; `Notifier`/`AsyncNotifier` for state; override in tests.
- **drift**: single DB; tables mirror server entities + `outbox` + `sync_state(cursor)`; all writes go through a
  repository that writes the row and the outbox entry in one transaction.
- **Offline-first**: UI reads from drift streams only; network is a background concern; client UUIDs.
- **Notifications**: see `notifications-specialist` (iOS 64 window, exact alarms, boot, actions).
- **l10n**: `flutter gen-l10n` with `app_ru.arb` / `app_en.arb`; no string literals in widgets.
- **Accessibility**: elderly mode = text scale >= 1.3, min tap target 56dp, high contrast; semantics labels on
  all actionable widgets; test with `tester.ensureSemantics()`.
- **Ads**: never on Today/reminder/dose-mark screens (TZ §1).

## Testing
```dart
testWidgets('marking a dose writes an outbox entry', (tester) async {
  final db = AppDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  await tester.pumpWidget(ProviderScope(
    overrides: [databaseProvider.overrideWithValue(db), clockProvider.overrideWithValue(FakeClock(...))],
    child: const PillPalApp(),
  ));
  await tester.tap(find.byKey(const Key('dose-take-<occurrence>')));
  await tester.pumpAndSettle();
  expect(await db.outboxDao.pending(), hasLength(1));
});
```

## Commands
```bash
cd packages/pillpal_core && dart pub get && dart format . && dart analyze --fatal-infos && dart test
cd app && flutter pub get && dart run build_runner build --delete-conflicting-outputs && flutter analyze && flutter test
```
Flutter/Dart cannot run in the Claude sandbox (pub.dev and storage.googleapis.com blocked) — CI verifies.
