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
| 2.5 | CI/CD | integration_test journey on Android emulator in CI, release APK/AAB artifacts, iOS build (no signing) | CI green incl. emulator job |

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

Out of scope (later phases): relatives/sharing UI (3), catalog + scanner (4), OAuth, ads, payments, analytics (5).
