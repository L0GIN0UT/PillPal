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

Out of scope (later phases): relatives/sharing UI (3), catalog + scanner (4), OAuth, ads, payments, analytics (5).
