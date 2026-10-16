# Phase 2 — Flutter app (offline core) — delivery plan

Source: docs/TZ.md §2, §5 "Фаза 2"; mockups in docs/design.md.
Constraint: Flutter/pub.dev are unreachable from the Claude sandbox, so every Dart/Flutter change is
verified by GitHub Actions (`app.yml`). Platform folders (`android/`, `ios/`) are generated once by the
`app-scaffold.yml` workflow (`flutter create` in CI, committed back to the branch).

Each milestone is one PR into `main`, merged only with green CI.

| # | Milestone | Content | Done when |
|---|---|---|---|
| 2.0 | App shell | `app/` project, platform scaffolding via CI, Riverpod, go_router, theme from design tokens (light/dark, senior scale), bundled Rubik/Nunito, gen-l10n RU/EN, bottom navigation with placeholder screens, CI: analyze + test + debug APK build | CI green, widget tests for theme/nav/l10n |
| 2.1 | Data + sync | drift schema (profiles, medications, schedules, dose_events, outbox, sync_state), repositories, API client (auth, sync push/pull), token storage (flutter_secure_storage), sync engine (outbox in order, pull with cursor, LWW apply), use of `pillpal_core` for occurrences | unit tests on in-memory drift + fake HTTP; contract test against backend schemas |
| 2.2 | Screens | onboarding + region confirm + register/verify/login; Today (occurrences from engine, mark taken/skip/snooze); medication add/edit (free input, privacy); schedule editor (all kinds); history calendar + adherence; settings (theme, senior mode, language, notification defaults) | widget tests per screen, golden-free |
| 2.3 | Reminders | notification planner (rolling window ≤ 64 on iOS, horizon on Android), levels quiet/normal/persistent/alarm, actions Taken/Snooze/Skip (background isolate → outbox), exact-alarm permission flow, boot/timezone-change reschedule, OEM battery onboarding | planner unit tests with fake clock/tz; adapter tests with fake plugin |
| 2.4 | Extras | stock tracking + "pharmacies nearby" deep link, PDF report for a period, home-screen widget | unit/widget tests |
| 2.5 | CI/CD | integration_test journey on Android emulator in CI (`app-emulator.yml`), release APK/AAB artifacts (`app-release.yml`), iOS build without signing (`app-ios.yml`) | CI green incl. emulator job |

### 2.5 emulator test plan (reminders)

`integration_test` on the Android emulator with the real plugin (no fake scheduler):

1. Create a medication with a reminder a minute ahead; the notification fires with the name and dose;
   with "Hide medication names in notifications" on, it shows the generic text.
2. Foreground: tap **Taken** on the notification; one `taken` event, the occurrence's other
   notifications leave the tray.
3. **Terminated app → Taken / Snooze.** Swipe the app away (and, separately, `am force-stop` followed
   by an app start, which must re-arm the alarms, ADR 0001 §3), let the reminder fire, tap **Taken**:
   exactly one `taken` event and one outbox entry after the next start, no duplicate on a double tap,
   tray cleared. Repeat with **Snooze**: a `snoozed` event with `snooze_until` = tap + 15 min and the
   snoozed notification firing at that time. The action runs in the plugin's
   `ActionBroadcastReceiver`, which has no `goAsync()`: assert the event is written within the
   receiver's window on a slow emulator image.
4. Reboot the emulator (`adb reboot`): pending reminders fire after boot.
5. Sign out: no pending alarm (`adb shell dumpsys alarm`) and an empty tray.

iOS (manual until a simulator job exists): the same scenarios 2-3 on a device with the Time Sensitive
capability enabled, and with Time Sensitive switched off in Settings (hint on the Today card).

#### What CI automates (`app-emulator.yml`)

Android 14 (API 34, google_apis x86_64) emulator, real backend, real plugin. One debug build of
`app/integration_test/app_test.dart` is installed once (`flutter install`) and run phase by phase with
`flutter drive --keep-app-running`; `flutter test integration_test` is not used because it uninstalls the
app after every run. `.github/scripts/emulator/run.sh` orchestrates; `host_control.py` (runner,
`10.0.2.2:8090`, test-only) serves the phase and the verification code from the backend log.
Permissions are granted up front (`pm grant POST_NOTIFICATIONS`, `appops set SCHEDULE_EXACT_ALARM allow`).

| Plan item | Automated as |
|---|---|
| Onboarding | `onboarding`: register, verify, add a medication, daily dose ~3 min ahead via the time picker, Today shows it, sync |
| 1. Fires with name and dose; generic text with hidden names | Pending request (plugin) titled with the name, generic title/body while "hide names" is on, back after; the fired notification (`dumpsys notification --noredact`) carries the name |
| 3. Terminated app -> Taken | Process killed after HOME (`am kill`, else `kill -9` via `run-as`: alarms survive, unlike force-stop), reminder fires, **Taken** tapped in the shade (uiautomator dump + `input tap`); `taken` phase: exactly one `taken` event for the occurrence and nothing else, nothing pending or in the tray for it, Today shows it taken, outbox synced; backend has exactly one `taken` event |
| 3. Force stop + start re-arms (ADR 0001 §3) | `am force-stop` empties AlarmManager for the app; `rearm` phase starts the app; `dumpsys alarm` lists its alarms again |
| 5. Sign out | `sign_out`: no pending request, empty tray, local data erased; no alarm of the app in `dumpsys alarm` |

#### Manual checklist (not deterministic on a CI emulator)

- **2. Foreground Taken**: the tap would have to happen while a drive phase is running; the background
  path is the same receiver and is covered above, the main-isolate hand-over by unit tests.
- **3. Double tap**: the first tap cancels the notification, so a second tap cannot be driven through the
  system UI; the duplicate guard (`alreadyHandled`) is unit-tested.
- **3. Snooze**: the snoozed reminder fires 15 min later, which would double the job's runtime; the
  `snoozed` event and the snooze series are unit-tested. Check on a device.
- **3. Swipe from recents**: approximated by killing the backgrounded process (same effect on alarms);
  the real gesture is OEM-dependent.
- **4. Reboot**: `adb reboot` inside the emulator runner restarts the device under the action and its boot
  wait is unreliable; check on a device (also after an app update: `MY_PACKAGE_REPLACED`).
- **3. Slow receiver window**: the emulator is not slow enough to be meaningful; check on a low-end
  device.
- **iOS**: all scenarios above (`app-ios.yml` only compiles the project).

Artifacts of every run (`emulator-journeys`): screenshots, UI/alarm/notification dumps, logcat, drive and
backend logs. Synthetic data only (medication `Testamin`, `emulator-*@example.com`).

### 2.4 home-screen widget (Android)

- The app stores the open doses of **today and tomorrow** (instants, local time, title) and each day's
  "N из M" in the widget storage after every reminder re-plan (every write, start, resume, locale change)
  and after a notification action handled in the background. The native provider picks the current day
  and the first dose still ahead.
- **Redraws:** launchers do not redraw a widget by themselves and `updatePeriodMillis` is 0, so every
  update arms **one inexact, non-wakeup alarm** (`AlarmManager.set(RTC)`, never exact: that quota belongs to
  reminders) for the next transition: the next dose leaving its 30-minute grace, or the end of the current
  day. It replaces itself, fires when the device is awake next, and is cancelled when the last widget is
  removed. Time and time-zone changes redraw at once. After the two stored days the widget shows
  "Откройте PillPal".
- Titles follow the notification privacy rules (`hidden`/`anonymous` or "hide names" → generic text).
  Without a placed widget its storage is cleared; sign-out and an account switch write an empty widget.

### 2.4 follow-ups

- **iOS home-screen widget.** Android ships in 2.4 (`TodayWidgetProvider`, `home_widget`). iOS needs a
  WidgetKit extension target in `ios/Runner.xcodeproj` (Xcode), an App Group shared by the app and the
  extension (`HomeWidget.setAppGroupId`), and a `TimelineProvider` that builds entries from the stored
  `today_entries` instants (iOS widgets cannot be redrawn on demand at arbitrary times, so the timeline
  must carry the dose times). The data written by the app is already platform-neutral.
- **Duplicate continuations after offline splits** (ADR 0003, known limitations): deterministic
  continuation ids.

Out of scope (later phases): relatives/sharing UI (3), catalog + scanner (4), OAuth, ads, payments, analytics (5).
