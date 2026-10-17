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
  planner ids are `1..0x3fffffff`; `0x40000000..0x7fffffff`
  (`firstAppNotificationId`..) is reserved for the app's other notifications
  (low stock, sync prompts), so they never collide with reminders (planner
  spec §7). Scheduling an existing id replaces it: Android
  reuses the `PendingIntent` keyed by id with `FLAG_UPDATE_CURRENT`
  (`FLNP.java:689-695` `getBroadcastPendingIntent`), iOS adds a request with
  the same identifier (`FLNP.m:658-668`).
- `cancel({required int id, String? tag})` (`flutter_local_notifications_plugin.dart:345`)
  removes the pending **and the delivered** notification: Android cancels the
  alarm and `NotificationManager.cancel(id)` (`FLNP.java:1855-1867`); iOS calls
  `removePendingNotificationRequestsWithIdentifiers` and
  `removeDeliveredNotificationsWithIdentifiers` (`FLNP.m:683-691`). Hence
  `reconcile(..., now:)` never cancels requests whose fire time has passed
  (they may be in the tray, or still pending: Android delays inexact alarms
  and Doze defers exact ones), and `settleIds` cancels them only when they are
  obsolete — dose handled, snoozed, schedule deleted/disabled/edited — which
  also clears them from the tray (planner spec §8).
- `pendingNotificationRequests()` (`flutter_local_notifications_plugin.dart:665-666`)
  returns `PendingNotificationRequest(id, title, body, payload)` — no fire date
  (`flutter_local_notifications_platform_interface/lib/src/types.dart:17-37`;
  iOS `FLNP.m:275-300`). It cannot rebuild a plan, so the app persists every
  applied notification (`AppliedNotification`: request + fingerprints) in drift
  — past ones included — until it is settled or older than the retention
  window, and uses the pending list only as a consistency check (unknown
  pending ids in the planner range are cancelled; known future ones missing
  from it are re-scheduled).
- **The pending list is not the OS state on Android.** There
  `pendingNotificationRequests()` reads the plugin's own SharedPreferences
  cache (`scheduled_notifications`; `FLNP.java:1617-1620`
  `loadScheduledNotifications`), not AlarmManager, which cannot be queried.
  A force stop or an OEM task killer cancels the app's alarms but leaves the
  cache, so the list still reports them as pending. Therefore the first
  successful re-plan of every Android process re-arms **all** future
  rendered notifications with `zonedSchedule` (same id, so it replaces in
  place and is idempotent); later re-plans of the process trust the list.
  On iOS the list comes from `UNUserNotificationCenter` and is trusted.
- `cancelAll()` (`flutter_local_notifications_plugin.dart:365`) clears the
  app's notifications: Android `NotificationManager.cancelAll()` plus every
  cached alarm (`FLNP.java:1869-1890`), iOS all pending and delivered
  requests (`FLNP.m:694-698`). Used when the account's data is erased
  (ADR 0002 §1).
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
  Implementation: `ios/Runner/Runner.entitlements` holds the entitlement and
  is set as `CODE_SIGN_ENTITLEMENTS` for the Debug, Release and Profile
  configurations of the Runner target (edited without Xcode). **Manual
  step before the first signed build:** in Xcode, Runner → Signing &
  Capabilities, check that "Time Sensitive Notifications" is listed (add it
  there if Xcode does not pick the file up) so that the App ID and the
  provisioning profile get the capability; without it signing fails or the
  level silently degrades. The app reads
  `UNNotificationSettings.timeSensitiveSetting` over the `pillpal/device`
  channel (`AppDelegate.swift`); when it is `disabled` and the plan has
  persistent or alarm reminders, `ReminderStatus.timeSensitiveDegraded` is
  set and the Today card shows a hint that opens the notification settings.

### 7. Actions: Taken / Snooze / Skip, from a terminated app

- Android: per notification, `AndroidNotificationAction(id, title,
  showsUserInterface: false, cancelNotification: true)`
  (`android/notification_details.dart:50-62`, defaults `showsUserInterface:
  false`, `cancelNotification: true`). Background actions go through
  `ActionBroadcastReceiver` (manifest above). `cancelNotification` only
  removes the tapped notification; the other notifications of the occurrence
  are removed by settling (below).
- **Grouping per occurrence**, so a persistent series does not pile up as
  separate tray entries: Android `AndroidNotificationDetails.groupKey` and iOS
  `DarwinNotificationDetails.threadIdentifier` are both set to an opaque
  per-occurrence value — `fnv1a32(occurrenceKey)` in hex, not the key itself,
  which encodes dose times (`android/notification_details.dart:124`,
  `darwin/notification_details.dart:19`). An action on any notification of the
  group cancels **all retained ids of that occurrence**: the handler records
  the event, then `settleIds` (handled or snoozed key) returns every id of the
  occurrence — pending, delayed or delivered — and the adapter cancels them.
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
- In the handler: call `DartPluginRegistrant.ensureInitialized()` first,
  open drift in that isolate and, in **one transaction** — the "already
  handled" check included, so two simultaneous taps record one event —
  append the dose event (`taken` / `skipped` / `snoozed`) and its outbox
  entry. Then the re-plan (settle, plan, reconcile, §9) runs in **one**
  isolate only: the handler sends `[dose_event_recorded, replyPort]` to the
  port the main isolate registers in `IsolateNameServer`; if the main isolate
  answers within 2 s it re-plans (and pushes the outbox), else — app not
  running, or a registration left by a detached engine — the background
  isolate re-plans itself. No UI, no network.
- **Background execution window.** iOS: the plugin calls the response's
  completion handler right after starting the background engine
  (`FLNP.m:1160-1183`), after which iOS may suspend the app mid-write;
  `AppDelegate` wraps Taken / Snooze / Skip in
  `beginBackgroundTask` / `endBackgroundTask` for up to 25 s. Android: the
  plugin's `ActionBroadcastReceiver.onReceive` starts (or reuses) a static
  background engine and returns without `goAsync()`
  (`android/.../ActionBroadcastReceiver.java:51-89`), so the process has no
  receiver-bound time guarantee; the work normally finishes within a second
  while the process is cached, but a killed process loses an unfinished
  write (the dose stays unmarked on Today and the tapped notification is
  already gone). Covered by the terminated-app scenario of the 2.5 emulator
  plan (`docs/phase2-plan.md`); a native receiver with `goAsync()` is the
  fallback if it proves flaky.
- **Dose-event ids are random UUIDv4**, generated once per user action and
  stored with the outbox entry; retries resend the stored id, so idempotency
  comes from the outbox, not from deriving the id. Deriving it from
  `(occurrenceKey, action)` would collide for legitimate repeats — a second
  snooze, or taken → undo → taken — and the server would reject the second
  event as a conflict. A `taken` / `skip` response for an occurrence that is
  already handled is ignored locally.
- **Snooze needs a backend contract change** (milestone 2.3 task, below): the
  `snoozed` event must carry `snooze_until`, so that every device and the
  server's missed-dose detector agree when the snoozed dose is due. Today
  `DoseEventData` (`backend/app/schemas/entities.py:232-238`) has no such field
  and rejects unknown keys (`extra="forbid"`).

### 8. Payload and visible text

Payload: compact JSON `{"k": occurrenceKey, "m": medicationId}` — opaque ids
and the key only; nothing medical is logged or sent to analytics.

Visible text (owner decision, 2026-10-16):

| Medication privacy | Device setting "Hide medication names in notifications" off (default) | on |
|---|---|---|
| `shared` | name and dose ("Time to take X", "Dose: 1 tab.") | generic ("Time for your medication") |
| `anonymous`, `hidden` | generic | generic |

The setting is device-local, stored with the reminder defaults
(`reminder_defaults.hide_medication_names`), exposed in the default reminder
settings, and kept on sign-out like the other device preferences. Whether a
reminder shows the name (`shared` and the setting off) is part of the
schedule fingerprint, so toggling the setting settles every notification of
the affected (`shared`) medications — pending ones and those already in the
tray — and the plan re-creates what is still due with the new text, like a
privacy change of a medication (§9). The setting is also part of the display
fingerprint. Android
notifications set `visibility: NotificationVisibility.private`, so a secure
lock screen also follows the system setting "hide sensitive content".

### 9. Mapping the planner output to the plugin

```
now       = clock.now()
retained  = drift.appliedNotifications()            // past AND future, until settled
live      = {scheduleId: scheduleFingerprint for every enabled source}
settled   = settleIds(retained, handledKeys, snoozedUntil.keys, live)
for id in settled: cancel(id: id)                   // also clears the tray
retained -= settled;  drift.forget(settled)
plan      = ReminderPlanner(budget: B).plan(now:, deviceTz:, sources:, handledKeys:,
                                            snoozedUntil:, retained: retained.requests)
next      = [AppliedNotification(r, displayFingerprint: displayFor(r),
                                    scheduleFingerprint: live[r.scheduleId]) for r in plan.requests]
diff      = reconcile(retained, next, now: now)
for id in diff.cancelIds:  cancel(id: id)           // cancel FIRST (iOS 64 limit)
for a  in diff.schedule:   if a.request.fireAtUtc > clock.now():
                             zonedSchedule(
                               id: a.id,
                               scheduledDate: TZDateTime.from(a.request.fireAtUtc, tz.UTC),
                               notificationDetails: detailsFor(a),  // §6, group §7, actions §7
                               androidScheduleMode: modeFor(a.request.level, exactAllowed), // §4
                               title/body: textFor(a), payload: payloadFor(a.request))
drift.forget(diff.cancelIds not rescheduled); drift.upsert(next)   // past retained rows stay
drift.forget(rows whose fire time is older than the retention window)
request a background re-plan before plan.replanBefore (best effort)
```

`displayFor(r)` is an opaque string over everything that changes the
presentation: level → channel / interruption level, exact vs inexact mode,
medication privacy (`shared` / `anonymous` / `hidden`), app locale and the
text variant. A change of any of them cancels and reschedules the future
notification under the same id (planner spec §8.1). `scheduleFingerprint` is
a digest of the significant fields (rule, `tz_mode`, `fixed_tz`, level, N, M,
on/off, privacy — not the sync `version`, see Addendum); editing either settles
everything already applied for that schedule, delivered ones included, so a
medication made `hidden` also disappears from the tray, and the plan re-creates
what is still due with the new text.

Display-change triggers that must cause a re-plan: exact-alarm permission
granted or revoked (checked on resume), notification or full-screen permission
changes, privacy or level change of a medication (sync or UI), app language
change, Time Sensitive toggled by the user (detected on resume).

| `NotificationRequest` | Plugin |
|---|---|
| `id` | `id` (stable, sticky, `1..0x3fffffff`) |
| `fireAtUtc` | `scheduledDate` in `tz.UTC` |
| `level` | channel / `AndroidScheduleMode` / `interruptionLevel` |
| `occurrenceKey`, `medicationId` | `payload`; group / thread id from a hash of the key |
| `repeatIndex`, `isSnooze` | text variant ("still not taken", "snoozed") |

- Budget `B`: iOS `iosPendingNotificationLimit - 4` = 60 (headroom for
  non-planner notifications); Android `androidDefaultNotificationBudget` = 400
  (Samsung caps AlarmManager at 500 per app, README `:139`). Cancelling before
  scheduling matters on iOS, which keeps only the **64 most recently set**
  requests (README `:143`): exceeding it silently drops older ones.
- Re-plan triggers: app start, resume, every mark/snooze (UI or background
  action), sync pull that changed medications/schedules/dose events, settings
  and permission changes, the display triggers above, a device zone change
  detected on resume, and `replanBefore`.
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

## Tasks for milestone 2.3 (outside this PR)

- **Backend, sync-contract change**: add optional `snooze_until`
  (timezone-aware instant) to `snoozed` dose events — required for
  `type = snoozed`, forbidden otherwise — in `DoseEventData` / `DoseEventOut`,
  the `dose_events` table (Alembic migration `0002`, reversible), sync push
  and pull, and the missed-dose detector (a snoozed occurrence is due at
  `snooze_until`). Flag it in the PR body as a sync protocol change.
- App: drift table of `AppliedNotification`s with both fingerprints; outbox
  entries carry the event's UUIDv4.

## Alternatives considered

- `matchDateTimeComponents` (repeating calendar triggers): fewer iOS slots, but
  cannot express course ends, `interval_days`, handled doses or bounded repeats.
- `periodicallyShow` for persistent repeats: cannot stop after M repeats or on
  a mark without the app.
- Scheduling in the occurrence's zone: ambiguous at DST overlap on Android (§2).
- `USE_EXACT_ALARM`: Play policy risk (TZ §6).
- Treating a fire time `<= now` as delivered and forgetting it: wrong on
  Android (inexact alarms and Doze deliver late) and leaves obsolete reminders
  in the tray.
- Deterministic dose-event ids from `(occurrenceKey, action)`: collide on
  repeated snoozes and taken → undo → taken.

## Open questions

- AlarmKit (iOS 26+) for the alarm level: plugin choice and review risk.
- A native `TIMEZONE_CHANGED` / `TIME_SET` receiver that triggers a Dart
  re-plan without opening the app.
- Background re-plan mechanism (`BGAppRefreshTask` / WorkManager) — new
  dependency, separate ADR.

## Addendum (milestone 2.3 implementation)

- **Fingerprints** are SHA-256 digests of the significant fields only
  (`app/lib/src/reminders/fingerprints.dart`). Row versions / conflict keys
  are excluded: a pull that rewrites identical content would otherwise
  cancel and reschedule every notification. Display: level, exact/inexact,
  privacy, locale and the rendered title/body.
- **Android group summary.** A `groupKey` without a summary notification
  does not bundle: Android shows such children individually and excludes
  them from auto-grouping; Android 15+ "notification force grouping"
  (AOSP `GroupHelper`, bug 336488844) moves summary-less children into an
  app-wide aggregate group after ~3 s. A per-occurrence summary would need an
  extra scheduled notification per occurrence (more alarms, more ids to
  settle). Decision: Android notifications carry **no** `groupKey`; the
  system auto-groups the app's notifications, and settling an occurrence
  cancels all of its notifications anyway. iOS keeps `threadIdentifier` per
  occurrence (threads need no summary).
- **Reminder settings are device-local** (drift tables `reminder_defaults`,
  `medication_reminder_settings`, schema version 2), not synced.
- **Background isolate.** Actions run in the plugin's separate engine. The
  database is opened with `shareAcrossIsolates` and `busy_timeout`; the
  handler hands the re-plan over to the main isolate through
  `IsolateNameServer` (`pillpal.reminders.events`, §7), which refreshes its
  streams and pushes the outbox. Tokens and the network are never used in
  the background. The background isolate never re-arms (§3): that is left
  to the next app start.
- **Fingerprints are pseudonymised**, not anonymous: unsalted SHA-256 over
  medical text, so whoever holds the database can confirm a guessed name.
  The same database stores the names in clear and is erased with them, so
  no keyed HMAC is used.
- **Platform failures.** Every `zonedSchedule` is guarded on its own: a
  refused notification does not stop the others, is not stored as applied
  (the next re-plan retries it) and marks the status `failed`; a failed
  re-plan is retried with exponential backoff (1 min doubling to 30 min). A
  failing `initialize` does not stop the re-plan triggers.
- **Sign-out and account switch** cancel every notification and forget the
  applied ones (ADR 0002 §1).
- **Full-screen intent** is not used yet (Play declaration pending); the
  alarm level uses the alarm channel + `alarmClock` mode.

## Addendum (milestone 3.7: background upload of marks, sync lease, refresh reuse window)

Why: the missed-dose detector (ADR 0007) alarms relatives when no mark reaches
the server. A Taken/Skip/Snooze tapped in the notification with the app killed
used to wait for the next app start. This addendum changes two statements above:
"Tokens and the network are never used in the background" (§7, 2.3 addendum)
and "which pushes the outbox".

**1. Background network is allowed for the outbox flush only.**
- After the handler records an event (`ReminderActionOutcome.recorded`) and the
  re-plan is done, it queues a flush (`onRecorded`, bounded by 10 s: a hung
  platform channel never delays the re-plan or the snooze series). Nothing else
  in the background touches the network: no pull (relatives' data is never
  fetched in the background), no registration. The flush is
  `SyncEngine.sync(pull: false)`: the outbox in `seq` order, results applied
  like in the foreground.
- Android: one WorkManager job per recorded action (`workmanager`, network
  constraint `connected`, exponential back-off from 30 s), all in one unique
  chain (`pillpal.flush`, `ExistingWorkPolicy.append`): never dropped, never
  cancelled while running. The job runs `backgroundFlushDispatcher` in its own
  engine, may refresh the session (under the lease) and returns `false` (retry)
  only for `retryLater` (offline, lease busy/lost, 5xx, rate limit, deferred
  refresh). The main isolate is not asked first: it may be frozen, and a second
  push is idempotent.
- iOS: no WorkManager. The handler flushes inline, inside the background task
  of `AppDelegate.keepRunningForAction` (25 s), with a real deadline of 20 s:
  the lease wait is capped by it, at the deadline the HTTP client is closed
  (aborting the request in flight) and the flush is awaited (lease released)
  before the database is closed. **It never rotates the refresh token**: a
  rotation whose response is lost to a suspension would leave a spent token on
  the device. If the access token is expired or within 60 s of expiry, the flush
  is skipped; a 401 ends it as `refresh_deferred`. The app start (no deadline)
  refreshes and pushes.
- Account guard: the job carries the id of the account the local data was bound
  to when the event was recorded. Nothing is sent unless the stored session
  *and* the binding are that account; a sign-out or another sign-in wipes the
  outbox and the job ends as `accountChanged`/`signedOut`. A background refresh
  (`BackgroundSession`) never binds or erases: an unexpected account fails it.
- Logging: no logs in the flush at all (errors may carry medical data); the
  outcome is an enum. The job input is the opaque account UUID.
- A background engine changes the outbox in its own connection; the main
  isolate re-queries the outbox and dose events when the app resumes.

**2. One sync lease (drift table `sync_leases`, schema 5, `CHECK (id = 1)`).**
- One row: `holder` (random id per acquisition), `epoch` (+1 per acquisition),
  `expires_at`. Acquire, renew and release are single guarded `UPDATE`s, atomic
  between isolates and engines sharing the database file.
- TTL 90 s: longer than a request and its body (2 x the 30 s HTTP timeout).
  Holders renew before every push request and inside every transaction that
  applies results (each pull page included), and the refresh renews before and
  after its request; a dead holder frees the lease by expiry. A clock moved
  back is covered: a lease whose `expires_at` is further away than one TTL is
  treated as lapsed.
- Everything that rotates the refresh token or applies push/pull results holds
  the lease: a sync run for its whole duration (`SyncEngine`), a refresh
  (`ApiClient`), a sign-out (`signOutLocally`, which drops the binding before
  it clears the tokens, so no refresh can store tokens after it; if the lease
  stays busy the sign-out goes on anyway). `run` is re-entrant in the same zone
  while its scope is alive (a flag set in `finally`), so a run that holds the
  lease refreshes without asking again.
- Fencing: before persisting tokens, before clearing them after a 401, and in
  the transaction that applies results the holder calls `ensure` (holder id and
  epoch must still match and not be expired). A stale holder gets `LeaseLost`:
  the sync run ends `lease_lost` with nothing applied; a refresh adopts the
  tokens the new holder stored (or fails `lease_lost`). It never stores or
  forgets tokens.
- Waiting: a foreground runner (screens, app sync) waits at most 5 s, then the
  run is **deferred**, not failed: `sync_busy`, `lease_lost` and
  `refresh_deferred` leave the sync status idle (no error badge) and the next
  trigger syncs again. A 401 refresh from a screen therefore never hangs behind
  a background job. A background job waits up to 100 s (> TTL), so a dead
  holder has expired by then.
- Lease instants are device-clock instants: every holder runs on this device.

**3. Backend: refresh reuse window (`REFRESH_REUSE_WINDOW_SECONDS`, default 120).**
- A killed isolate can lose the response of a rotation. Without a window its
  retry would be reuse and revoke the family, signing the user out.
- Why 120 s and not 30 s: the retry can come from a job that waited for the
  lease (TTL 90 s) and then made its request (up to 30 s), or from a WorkManager
  back-off. The window must cover lease TTL plus a request timeout. The iOS
  window never rotates, so the only rotations that can be lost are the main
  app's and Android jobs'. Because the window answers **once** (below), the
  longer window adds little for a thief.
- A rotation stores the new pair in Redis under `rr:` + `sha256(old token)` with
  a TTL of the window; the value is AES-GCM encrypted with a key derived
  (HKDF-SHA256) from the old token, with the device id of that rotation (the
  `X-Device-ID` of the request, else the token's device) inside the ciphertext.
  A repeat of the same old token returns the pair only if all hold: the token is
  still within the window by `used_at`, not revoked or expired, the account is
  not pending deletion, the cached pair's refresh token is still the unspent
  head of the family (a lost response never saw it; if it moved on, the repeat
  is not a retry), the request carries the same `X-Device-ID` (constant-time
  comparison) and the entry decrypts. The entry is read with `GETDEL`: the
  window answers once, a second repeat is reuse and revokes the family.
  Otherwise it is reuse and revokes the family as before. Rotations without a
  device get no window.
- The entry is written before the commit under the token row lock, so a
  concurrent duplicate that waits for the lock finds it. Both Redis calls run
  under those locks and are bounded (`REFRESH_REUSE_REDIS_TIMEOUT_SECONDS`, 1 s).
- Redis failure or timeout: **fail closed**. Rotation never depends on Redis (a
  failed write is logged without values and rotation succeeds); a repeat while
  Redis is down, or with a missing or tampered entry, gets no pair and is
  treated as reuse (the same outcome as before the window existed). The
  alternative, a retryable 503, only postpones the revoke past the window.
- Not logged: tokens, the cache value, the Redis key.
- The window is a deliberate weakening: a thief who holds the old token *and*
  presents the same `X-Device-ID` within the window, before the owner's repeat,
  gets the pair. The device id is not a secret; the protection is that the entry
  is single use and that the old token must have been stolen within the window.
