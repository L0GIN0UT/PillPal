# ADR 0001 — Local notifications for reminders (milestone 2.3)

- Status: proposed (owner review)
- Date: 2026-10-16
- Scope: Flutter app, milestone 2.3 "Reminders" (`docs/phase2-plan.md`); TZ §2.3, §3, §6
- Related: `docs/spec/reminders.md` (planner), `docs/spec/schedule.md` (engine),
  `.claude/agents/notifications-specialist.md`

## Context

Reminders are local and must fire offline and after a reboot (TZ §3). The
pure planner in `pillpal_core` (`ReminderPlanner`, `reconcile`) already decides
**which** notifications exist, **when** (UTC instants, DST handled by the
engine) and with **which stable id**. This ADR fixes the platform layer that
turns a plan into pending OS notifications.

Sources read (as data, nothing executed; pub.dev is blocked in the sandbox):

| Source | Revision |
|---|---|
| `MaikuB/flutter_local_notifications` | tag `flutter_local_notifications-v22.3.2`, commit `2a1157a` (2026-10-12) — latest stable |
| same, `master` | `23.0.0-dev.4`, commit `e281315` (2026-10-13) — pre-release, for comparison only |
| `tjarvstrand/flutter_timezone` | `master`, version 5.1.1 (2026-10-03) |
| `srawlins/timezone` | `master`, version 0.11.0 |

Paths below are relative to the package directory `flutter_local_notifications/`
of the plugin repository at v22.3.2 unless stated otherwise; `FLNP.java` is
`android/src/main/java/com/dexterous/flutterlocalnotifications/FlutterLocalNotificationsPlugin.java`
and `FLNP.m` is
`ios/flutter_local_notifications/Sources/flutter_local_notifications/FlutterLocalNotificationsPlugin.m`.

## Decision

### 1. Dependencies

| Package | Constraint | Reason |
|---|---|---|
| `flutter_local_notifications` | `^22.3.2` | Latest stable. Requires Dart `^3.10.0`, Flutter `>=3.38.1` (`pubspec.yaml`), fine for Flutter stable with Dart 3.11. `23.0.0-dev.*` requires Flutter 3.44 / Dart 3.12 and AGP 9.1.1 (`CHANGELOG.md`, 23.0.0-dev.1) — not usable on our CI and not stable. |
| `timezone` | `^0.11.0` | The plugin depends on `timezone: ^0.11.0` (`pubspec.yaml`). `pillpal_core` allows `>=0.9.4 <0.12.0`, so one version (0.11.x) is resolved for both. 0.11.0 changed `Location.offset` to `Duration` (timezone `CHANGELOG.md`); the engine only uses `Location.translate` (`docs/spec/schedule.md` §7), so it is unaffected. |
| `flutter_timezone` | `^5.1.1` | `FlutterTimezone.getLocalTimezone()` returns `TimezoneInfo` whose `identifier` is the IANA id (flutter_timezone `lib/flutter_timezone.dart:19`, `lib/timezone_info.dart:18`). Android: `ZoneId.systemDefault().id` (`android/.../FlutterTimezonePlugin.kt:71-76`); iOS: `NSTimeZone.name` (`ios/.../FlutterTimezonePlugin.m:42`). The plugin's own example uses it the same way (`example/lib/main.dart:223-228`). |

API shape note: since 20.0.0 `initialize`, `show`, `zonedSchedule`, `cancel`
take **named** parameters (`CHANGELOG.md`, 20.0.0); older snippets on the web
do not compile.

### 2. Time zones: initialise once, schedule in UTC

```dart
tzdata.initializeTimeZones();                       // latest_all, required by the engine
final info = await FlutterTimezone.getLocalTimezone();
final deviceTz = info.identifier;                   // passed to ReminderPlanner.plan
tz.setLocalLocation(tz.getLocation(deviceTz));      // guard: unknown id -> profile zone
```

This runs before the engine's lazy `ensureTimeZonesInitialized()` so that
`tz.local` is not reset (`docs/spec/schedule.md` §7). If `getLocation` throws
for the reported id, the app falls back to the profile's `timezone`; the
planner reports any source it cannot plan (`unplannableScheduleIds`).

**Every notification is scheduled as a `TZDateTime` in `tz.UTC`**:
`tz.TZDateTime.from(request.fireAtUtc, tz.UTC)`. Reason: `zonedSchedule`
sends the zone name plus a *wall-clock* string over the channel
(`lib/src/tz_datetime_mapper.dart:3-29`), and Android rebuilds the instant
with `ZonedDateTime.of(LocalDateTime.parse(...), ZoneId.of(timeZoneName))`
(`FLNP.java:619-623`). For an ambiguous wall time (DST overlap) Java picks
the earlier offset, so a persistent repeat at 02:30 CET (second pass) would
fire an hour early. iOS builds a `UNCalendarNotificationTrigger` from calendar
components in the given zone (`FLNP.m:872-934`). In UTC the wall clock is
never ambiguous, the planner's instants are delivered exactly, and DST
semantics stay in one place (the engine). A device zone change therefore does
not move pending notifications by itself; for `tz_mode=local` the app re-plans
(planner spec §9) and `reconcile` re-schedules the moved ids in place.

### 3. `zonedSchedule` and related APIs (v22.3.2)

```dart
Future<void> zonedSchedule({            // lib/src/flutter_local_notifications_plugin.dart:409-418
  required int id,
  required TZDateTime scheduledDate,
  required NotificationDetails notificationDetails,
  required AndroidScheduleMode androidScheduleMode,
  String? title,
  String? body,
  String? payload,
  DateTimeComponents? matchDateTimeComponents,   // we never set it
});
```

- `scheduledDate` before `clock.now()` throws `ArgumentError`
  (`lib/src/helpers.dart:8-22`, called from both platform implementations:
  `lib/src/platform_flutter_local_notifications.dart:258` Android,
  `:828` iOS). The adapter re-checks `fireAtUtc > now` right before each
  call (the planner already returns only future instants). Precision is one
  second (doc comment at `flutter_local_notifications_plugin.dart:383-386`).
- `id` must fit a signed 32-bit int
  (`flutter_local_notifications_platform_interface/lib/src/helpers.dart:4-14`);
  planner ids are `1..2^31-1`. Scheduling an existing id replaces it: Android
  reuses the `PendingIntent` keyed by id with `FLAG_UPDATE_CURRENT`
  (`FLNP.java:689-695` `getBroadcastPendingIntent`), iOS adds a request with
  the same identifier (`FLNP.m:658-668`).
- `cancel({required int id, String? tag})` (`flutter_local_notifications_plugin.dart:345`)
  removes the pending **and the delivered** notification: Android cancels the
  alarm and `NotificationManager.cancel(id)` (`FLNP.java:1855-1867`); iOS calls
  `removePendingNotificationRequestsWithIdentifiers` and
  `removeDeliveredNotificationsWithIdentifiers` (`FLNP.m:683-691`). Hence
  `reconcile(..., now:)` ignores already-fired requests (planner spec §8), and
  the app cancels an occurrence's ids explicitly when the dose is marked, which
  also clears it from the tray.
- `pendingNotificationRequests()` (`flutter_local_notifications_plugin.dart:665-666`)
  returns `PendingNotificationRequest(id, title, body, payload)` — no fire date
  (`flutter_local_notifications_platform_interface/lib/src/types.dart:17-37`;
  iOS `FLNP.m:275-300`). It cannot rebuild a plan, so the app persists the last
  applied requests in drift and uses the pending list only as a consistency
  check (unknown pending ids are cancelled, known-but-missing ones re-scheduled).
- `getActiveNotifications()` (`:699-700`) and `getNotificationAppLaunchDetails()`
  (`:216`) — the latter routes a cold start from a tapped notification.

### 4. Android: schedule modes and exact alarms

`AndroidScheduleMode` (`lib/src/platform_specifics/android/schedule_mode.dart:5-30`):
`alarmClock`, `exact`, `exactAllowWhileIdle`, `inexact`, `inexactAllowWhileIdle`.
Native mapping (`FLNP.java:749-795`): `exactAllowWhileIdle` →
`setExactAndAllowWhileIdle`, `alarmClock` → `setAlarmClock`,
`inexactAllowWhileIdle` → `setAndAllowWhileIdle`. Exact modes and
`alarmClock` call `checkCanScheduleExactAlarms` on API 31+ and throw
`ExactAlarmPermissionException` (`FLNP.java:797-801`), surfaced to Dart as
`PlatformException(code: 'exact_alarms_not_permitted')`
(`FLNP.java:205`, `:1691-1705`, `:2470-2474`).

| Level | Exact alarms allowed | Not allowed |
|---|---|---|
| quiet, normal, persistent | `exactAllowWhileIdle` | `inexactAllowWhileIdle` |
| alarm | `alarmClock` | `inexactAllowWhileIdle` |

Permission flow (TZ §2.3, §6 — `SCHEDULE_EXACT_ALARM`, **not** `USE_EXACT_ALARM`):
1. `AndroidFlutterLocalNotificationsPlugin.canScheduleExactNotifications()`
   (`lib/src/platform_flutter_local_notifications.dart:637-639`; native
   `FLNP.java:2414-2421`, always `true` below API 31).
2. If `false`: explain, then `requestExactAlarmsPermission()` (`:179-180`;
   native opens `ACTION_REQUEST_SCHEDULE_EXACT_ALARM` for the package,
   `FLNP.java:1941-1966`).
3. If still denied: schedule inexact, show a persistent banner on Today.
   Re-check on every resume. On `exact_alarms_not_permitted` from any call the
   adapter re-applies the whole plan in inexact mode.

On boot the plugin re-arms from its own cache and silently **drops** entries
whose exact scheduling fails (`FLNP.java:229-245`), another reason to re-plan
on every app start.

### 5. Android manifest, permissions, Gradle

The plugin's manifest only adds `VIBRATE` and `POST_NOTIFICATIONS`
(`android/src/main/AndroidManifest.xml`). The app adds (README
"AndroidManifest.xml setup", `README.md:372-410`; example
`example/android/app/src/main/AndroidManifest.xml:2-67`; the example also
requests `USE_EXACT_ALARM`, which we do not):

```xml
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
<uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM"/>
<uses-permission android:name="android.permission.USE_FULL_SCREEN_INTENT"/> <!-- alarm level, §6 -->

<application>
  <activity android:name=".MainActivity" android:showWhenLocked="true" android:turnScreenOn="true" ...>
  <receiver android:exported="false"
      android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver"/>
  <receiver android:exported="false"
      android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">
    <intent-filter>
      <action android:name="android.intent.action.BOOT_COMPLETED"/>
      <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
      <action android:name="android.intent.action.QUICKBOOT_POWERON"/>
      <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>
    </intent-filter>
  </receiver>
  <receiver android:exported="false"
      android:name="com.dexterous.flutterlocalnotifications.ActionBroadcastReceiver"/>
</application>
```

- `POST_NOTIFICATIONS` (Android 13+) at runtime:
  `requestNotificationsPermission()` / `areNotificationsEnabled()`
  (`platform_flutter_local_notifications.dart:205-206`, `:624-625`).
- The boot receiver reacts only to boot / package-replaced
  (`android/.../ScheduledNotificationBootReceiver.java:13-22`) and runs no
  Dart. `TIME_SET` / `TIMEZONE_CHANGED` are not handled; UTC scheduling keeps
  existing alarms correct, and local-mode re-planning happens on the next app
  start or resume (see Consequences).
- Gradle (README "Gradle setup", `README.md:215-370`; plugin
  `android/build.gradle:11,26,35,45`): core library desugaring
  (`isCoreLibraryDesugaringEnabled = true`,
  `coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")`),
  Java 17, `compileSdk = 36` (README minimum 35), `minSdk = 24` (plugin
  `minSdkVersion 24`; CHANGELOG 21.0.0), AGP >= 8.11.1. R8: keep the
  notification icon drawables via `res/raw/keep.xml` (README "Release build
  configuration").

### 6. Channels and interruption levels per level

Android channel sound, vibration and importance are fixed at creation
(README, "Custom notification icons and sounds"), so channels are created
up front with `createNotificationChannel` (`platform_flutter_local_notifications.dart:500`)
and versioned ids; a change means a new id.

| Level | Android channel (`AndroidNotificationChannel`, `android/notification_channel.dart:10-25`) | Details (`AndroidNotificationDetails`, `android/notification_details.dart:111-160`) | iOS `interruptionLevel` |
|---|---|---|---|
| quiet | `reminders_quiet_v1`, `Importance.low`, `playSound: false`, `enableVibration: false` | `category: reminder` | `passive`, `presentSound: false` |
| normal | `reminders_normal_v1`, `Importance.high` | `category: reminder` | `active` |
| persistent | `reminders_persistent_v1`, `Importance.high` | `category: reminder`; repeats come from the planner | `timeSensitive` |
| alarm | `reminders_alarm_v1`, `Importance.max`, `audioAttributesUsage: AudioAttributesUsage.alarm`, alarm sound | `category: alarm`, `fullScreenIntent: true` only when granted | `timeSensitive` (AlarmKit: separate ADR) |

Enums: `Importance` (`android/enums.dart:145-165`), `AudioAttributesUsage.alarm`
(`:225-227`), `AndroidNotificationCategory.alarm` / `.reminder` (`:315-319`,
`:380-383`), `InterruptionLevel` (`darwin/interruption_level.dart:4-36`).

- **Full-screen intent policy**: only for the alarm level, only after the user
  opts into alarm mode. On Android 14+ the permission is granted by default
  only to calling/alarm apps and may be revoked by Play
  (`requestFullScreenIntentPermission` doc, `platform_flutter_local_notifications.dart:182-194`;
  native check `canUseFullScreenIntent` / `ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT`,
  `FLNP.java:1969-1995`). The system may show a heads-up instead; a launched
  full-screen intent is reported like a tap (`android/notification_details.dart:353-363`),
  so it opens the dose screen through `onDidReceiveNotificationResponse`.
  Expect a Play Console declaration; if refused, alarm degrades to heads-up.
- **iOS Time Sensitive** requires the "Time Sensitive Notifications"
  capability (entitlement `com.apple.developer.usernotifications.time-sensitive`;
  `darwin/interruption_level.dart:21-23`); the native side sets
  `content.interruptionLevel` on iOS 15+ only (`FLNP.m:834-844`). The user can
  disable it per app; it degrades to `active`. `critical` needs an Apple
  entitlement not granted for medication apps (TZ §6) — not used.

### 7. Actions: Taken / Snooze / Skip, from a terminated app

- Android: per notification, `AndroidNotificationAction(id, title,
  showsUserInterface: false, cancelNotification: true)`
  (`android/notification_details.dart:50-62`, defaults `showsUserInterface:
  false`, `cancelNotification: true`). Background actions go through
  `ActionBroadcastReceiver` (manifest above).
- iOS: one category registered at `initialize` via
  `DarwinInitializationSettings(notificationCategories: ...)`
  (`darwin/initialization_settings.dart:7-19`) with
  `DarwinNotificationAction.plain('taken' | 'snooze' | 'skip', title)`
  (`darwin/notification_action.dart:11-19`), **without**
  `DarwinNotificationActionOption.foreground`, so they run in the background.
  `AppDelegate` sets the `UNUserNotificationCenter` delegate and calls
  `FlutterLocalNotificationsPlugin.setPluginRegistrantCallback` — in
  `didInitializeImplicitFlutterEngine` if the generated app uses the UIScene
  lifecycle, else in `didFinishLaunchingWithOptions` (README `:469-483`,
  `:538-640`). Set `requestAlertPermission` etc. to `false` and request
  permissions during onboarding (`flutter_local_notifications_plugin.dart:89-98`).
- Handler: a top-level function

  ```dart
  @pragma('vm:entry-point')
  void onBackgroundNotificationResponse(NotificationResponse response) { ... }
  ```

  passed as `initialize(settings: ..., onDidReceiveNotificationResponse: ...,
  onDidReceiveBackgroundNotificationResponse: onBackgroundNotificationResponse)`
  (`flutter_local_notifications_plugin.dart:111-116`, doc `:100-110`). It must
  be static or top-level: the plugin stores its `CallbackHandle`
  (`platform_flutter_local_notifications.dart:1148-1168`) and runs it in a
  separate engine/isolate with no `Activity` (README `:525-534`, `:682-684`).
  `NotificationResponse` carries `notificationResponseType`, `id`, `actionId`,
  `input`, `payload` (`flutter_local_notifications_platform_interface/lib/src/types.dart:110-144`;
  types `selectedNotification`, `selectedNotificationAction`,
  `notificationDismissed`, `:163-172`).
- In the handler: open drift in that isolate, append the dose event
  (`taken` / `skipped` / `snoozed` with `until = now + snooze minutes`) plus
  its outbox entry in one transaction, with an id derived deterministically
  from the occurrence key and action so a double delivery records one event;
  cancel the occurrence's notification ids; re-run planner + `reconcile`. No
  UI, no network.

### 8. Payload and visible text

Payload: compact JSON `{"k": occurrenceKey, "m": medicationId}` — opaque ids
and the key only. Title/body follow per-medication privacy (`anonymous` →
"Time for your dose", localized); nothing medical is logged or sent to
analytics.

### 9. Mapping the planner output to the plugin

```
now      = clock.now()
plan     = ReminderPlanner(budget: B).plan(now:, deviceTz:, sources:, handledKeys:, snoozedUntil:)
previous = drift.lastAppliedRequests()      // checked against pendingNotificationRequests()
diff     = reconcile(previous, plan.requests, now: now)
for id in diff.cancelIds:  cancel(id: id)                         // cancel FIRST
for r  in diff.schedule:   zonedSchedule(
                             id: r.id,
                             scheduledDate: TZDateTime.from(r.fireAtUtc, tz.UTC),
                             notificationDetails: detailsFor(r.level),   // §6, category/actions §7
                             androidScheduleMode: modeFor(r.level, exactAllowed),  // §4
                             title/body: textFor(r), payload: payloadFor(r))
drift.saveAppliedRequests(plan.requests)
request a background re-plan before plan.replanBefore (best effort)
```

| `NotificationRequest` | Plugin |
|---|---|
| `id` | `id` (stable, 31-bit) |
| `fireAtUtc` | `scheduledDate` in `tz.UTC` |
| `level` | channel / `AndroidScheduleMode` / `interruptionLevel` |
| `occurrenceKey`, `medicationId` | `payload` |
| `repeatIndex`, `isSnooze` | text variant ("still not taken", "snoozed") |

- Budget `B`: iOS `iosPendingNotificationLimit - 4` = 60 (headroom for
  non-planner notifications); Android `androidDefaultNotificationBudget` = 400
  (Samsung caps AlarmManager at 500 per app, README `:139`). Cancelling before
  scheduling matters on iOS, which keeps only the **64 most recently set**
  requests (README `:143`): exceeding it silently drops older ones.
- Re-plan triggers: app start, resume, every mark/snooze (UI or background
  action), sync pull that changed medications/schedules/dose events, settings
  and permission changes, a device zone change detected on resume, and
  `replanBefore`.
- Adapter interface (`ReminderScheduler`) with a fake for widget tests; the
  real adapter is covered by `integration_test` on the emulator (milestone 2.5).

## Consequences

- Re-planning is idempotent and cheap: stable ids, minimal `cancel` /
  `zonedSchedule` calls, no cancel-all.
- DST correctness lives only in the engine; the platform receives UTC instants.
- iOS without background time: reminders after `replanBefore` exist only if
  the app ran (launch, foreground, background refresh, notification action).
  Heavy persistent levels shrink the window; the Today screen shows a banner
  when the plan was truncated (`droppedByBudget > 0`).
- After a long power-off Android re-arms past-due alarms from the plugin cache
  and AlarmManager fires past triggers immediately, so overdue reminders may
  arrive in a burst until the app re-plans.
- `tz_mode=local` reminders keep the old zone's instants until the app runs
  after a zone change.
- The UTC-scheduling and cancel-removes-delivered behaviour were verified in
  v22.3.2 sources; re-verify on every major upgrade of the plugin.

## Alternatives considered

- `matchDateTimeComponents` (repeating calendar triggers): fewer iOS slots, but
  cannot express course ends, `interval_days`, handled doses or bounded repeats.
- `periodicallyShow` for persistent repeats: cannot stop after M repeats or on
  a mark without the app.
- Scheduling in the occurrence's zone: ambiguous at DST overlap on Android (§2).
- `USE_EXACT_ALARM`: Play policy risk (TZ §6).

## Open questions

- AlarmKit (iOS 26+) for the alarm level: plugin choice and review risk.
- A native `TIMEZONE_CHANGED` / `TIME_SET` receiver that triggers a Dart
  re-plan without opening the app.
- Background re-plan mechanism (`BGAppRefreshTask` / WorkManager) — new
  dependency, separate ADR.
