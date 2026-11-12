# Backlog

Deferred work, with the owner decision that put it here. Entries move into a phase plan when they are scheduled.

## Owner decisions (2026-11-11)
- **First release is Android only.** iOS is not shipped for now: there are too many open issues (backups, APNs,
  AlarmKit, App Store review). The iOS code stays buildable (`app-ios.yml`), but iOS-only work is deferred.
- **Consent texts stay stubs** (version 1) for the field-test group. Final texts go in as version 2 after legal
  review (`docs/legal/README.md`).
- **Promo codes and ads stay off.** Backend `FEATURE_PROMO_CODES=false`, `FEATURE_PAYMENTS=false`,
  `REMOTE_CONFIG_ADS` unset (no ads). The app has no promo or ad UI and no ad SDK. A2 is deferred.

## Deferred
| Item | Why deferred | Notes |
|---|---|---|
| A2: entitlement cache, promo redeem sheet, ads gate (`docs/phase5-plan.md` §A2) | Promo codes and ads are off for the first release | Backend 5.4 / 5.10 / 5.12 are done and behind flags; the ads allowlist is `settings`, `about` (ADR 0018) |
| A3: analytics event allowlist, no-op sink | No analytics SDK in the first release | `docs/phase5-plan.md` §A3 |
| A4: region selection on Welcome + `/v1/config` read | One region per build for now (Q5) | `docs/phase5-plan.md` §A4 |
| OAuth sign-in buttons in the app (VK ID, Yandex ID; Apple, Google for EU) | Needs client ids in the provider consoles | Backend done (5.6–5.9); OAuth fallback signup timing oracle is an accepted residual |
| iOS: exclude the local database from iCloud/Finder backups (`NSURLIsExcludedFromBackupKey`, ADR 0002 follow-up) | iOS not shipped | Must be done before any iOS release; the privacy policy currently discloses the gap |
| iOS: reminders checklist, Time Sensitive, AlarmKit | iOS not shipped | `docs/phase2-plan.md` manual checklist |
| Consent texts version 2 (final RU texts; EU texts) | Waiting for legal review | Also fixes the two stub inaccuracies (notices go to relatives/guardians, PDF is built on the device); bump `CONSENT_VERSIONS_*` to `[1,2]` and `consent_documents.dart` together |
| Full-screen alarm surface (B2-Alarm, Q8) | Separate notifications milestone | Android 14 `USE_FULL_SCREEN_INTENT` policy |
| Resend button with countdown and outlined style (`AuthResendButton`) | UI follow-up from the PR #93 review | One shared widget change for every code screen |
| RU-Android push: RuStore Push as default, FCM as fallback | Architecture decision (`architect`) | Reduces cross-border metadata (privacy review of PR #99) |
| Legal fill-ins, RKN notification, operator form | Owner and lawyer | `docs/legal/README.md` |
| Hide «Регион: Россия» in the Settings account card | Owner has not decided yet | Hidden on registration in PR #104 |
| App motion pass (page transitions, tab paging, in-screen states) | Scheduled after reports PR 3 | Spec in the B2 README «Motion» |
| Unpin `flutter_rustore_push` 7.5.0 once 7.6.x restores the Kotlin JVM target | 7.6.0 sets Java 1.8 but drops `jvmTarget`, so the Android build fails | Pinned in `app/pubspec.yaml` (PR #112) |
| Gradle >= 9.5 and AGP >= 9.3.1 before Flutter drops Gradle 9.3.1 / AGP 9.1.1 | Warned in the Flutter 3.50 CI, not an error yet | KGP is still applied by firebase_core, home_widget, share_plus, workmanager_android and the RuStore stub |
