# ADR 0008 — Push delivery: FCM, APNs, RuStore (Phase 3)

- Status: accepted
- Date: 2026-10-16 (revised after the PR #12 reviews)
- Scope: TZ §2.5, §5 "Фаза 3" ("пуши FCM/APNs (+ RuStore Push для устройств без GMS)");
  backend `push_tokens`, `push_outbox`, `app/push/`; app `lib/src/push/`, Android Gradle,
  iOS `AppDelegate.swift`
- Related: ADR 0007 (what is sent and when), ADR 0005 (recipients), ADR 0001 §3 (app
  notification id range), ADR 0010 (tokens removed on deletion), `.claude/rules/privacy.md`
  rules 1, 3 and 8

## Context

Relatives receive missed-dose alerts, `resolved` follow-ups and "link accepted" notices.
Android devices with Google Play services use FCM; iOS uses APNs; many Android devices sold
in Russia have no GMS, and TZ §5 asks for RuStore Push for them. There are no credentials
yet (no Firebase project, APNs key or RuStore project), so the code must build, test and
run with every provider disabled. Medical data must never be in a push payload (privacy
rule 1).

Sources read (as data; nothing executed; pub.dev and provider endpoints are not reachable
from the sandbox's shell, pages were read through the documentation sites):

| # | Source | Revision / date read |
|---|---|---|
| S1 | FCM REST discovery document, `https://fcm.googleapis.com/$discovery/rest?version=v1` | revision `20260925`, read 2026-10-16 |
| S2 | FCM error codes, `https://firebase.google.com/docs/cloud-messaging/error-codes` | read 2026-10-16 |
| S3 | FCM token management, `https://firebase.google.com/docs/cloud-messaging/manage-tokens` | read 2026-10-16 |
| S4 | Apple, "Sending notification requests to APNs", `https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns` | © 2026, read 2026-10-16 |
| S5 | Apple, "Handling notification responses from APNs", `https://developer.apple.com/documentation/usernotifications/handling-notification-responses-from-apns` | © 2026, read 2026-10-16 |
| S6 | Apple, "Establishing a token-based connection to APNs", `https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns` | © 2026, read 2026-10-16 |
| S7 | RuStore, "Sending push notifications (API)", `https://www.rustore.ru/help/en/sdk/push-notifications/send-push-notifications` | read 2026-10-16 |
| S8 | RuStore, universal push API, `https://rustore.ru/help/sdk/general-push-notifications/send-push-notifications/api` | read 2026-10-16 |
| S9 | RuStore Flutter push SDK docs 7.2.0, `https://rustore.ru/help/sdk/push-notifications/flutter/7-2-0` (and 6.1.1 for comparison) | read 2026-10-16 |
| S10 | pub.dev `flutter_rustore_push`, `https://pub.dev/packages/flutter_rustore_push` and `/api/packages/flutter_rustore_push` | 7.2.0, published 2026-03-02 |
| S11 | pub.dev `firebase_core` (`/api/packages/firebase_core`, `FirebaseOptions` API docs) | 5.0.0, published 2026-10-15 |
| S12 | pub.dev `firebase_messaging` (`/api/packages/firebase_messaging`, changelog) | 17.0.0, published 2026-10-15; previous major 16.7.0 |
| S13 | Firebase blog, "Take Control of Your Firebase Init on Android", `https://firebase.blog/posts/2017/03/take-control-of-your-firebase-init-on` | 2017-03 |
| S14 | Firebase, "Add Firebase to your Flutter app", `https://firebase.google.com/docs/flutter/setup` | read 2026-10-16 |

## Decision

### 1. Providers and selection

| Platform | Provider | Token source |
|---|---|---|
| iOS | `apns` | raw APNs device token from a native method channel `pillpal/push` (`registerForRemoteNotifications`); no Firebase on iOS |
| Android with Google Play services and FCM configured | `fcm` | `firebase_messaging` |
| Android without GMS, RuStore Push available and configured | `rustore` | `flutter_rustore_push` |
| otherwise | none | Family settings say alerts about relatives are not available on this device |

The client decides and registers one token per installation
(`PUT /v1/push-tokens/current {provider, token, apns_environment?}` with `X-Device-ID`);
the server sends to every token of a recipient.

- **Registration only when needed.** The app initializes Firebase/RuStore and registers a
  token only while the user needs relative alerts: an incoming grant, a guardian role, a
  managed profile with co-guardians, or an open invite. When none remains it deletes the
  token. New and restored links are also shown by a Family-tab banner, so owners without a
  token still learn about them.
- **Validation:** format per provider (APNs `^[0-9a-f]{64,200}$`, because it is placed in
  the URL path; FCM and RuStore `^[A-Za-z0-9_:-]{1,4096}$`); at most
  `PUSH_MAX_TOKENS_PER_USER` (10) per user, so the server cannot be used to push to
  arbitrary tokens at scale.
- **Reassignment:** `UNIQUE(provider, token)`; registering a token held by another account
  moves it. Accepted risk: whoever obtains a device's token can take over that device's
  relative alerts (the token is not secret to the device's apps); documented, no mitigation
  beyond authentication.
- Logout deletes the token of the device bound to the refresh token
  (`refresh_tokens.device_id`); an account deletion request deletes all of them and drops
  pending outbox rows about the user's profiles (ADR 0010).
- Tokens never appear in logs, URLs we log, or Sentry breadcrumbs (URL breadcrumbs are
  disabled for the push senders).

### 2. Payload: ids only, rendered on the device

`PushPayload` (strict Pydantic, `extra="forbid"`) is the only way to build a payload:
`v` (1), `t` (`missed` | `resolved` | `link_accepted` | `link_restored`), `a` alert id, `p` subject profile id,
`m` medication id, `g` grant id, `s` (`u` = unconfirmed). A DB CHECK on
`push_outbox.payload` allows only these keys. No names, doses, times or occurrence keys
(the key encodes the schedule time) go over the wire.

- **Android (FCM, RuStore):** data-only, high-priority messages. A background handler with
  no network reads the subject profile's name and, for `shared` medications with "hide
  names" off, the medication name from local drift (already projected, ADR 0006), and
  shows a local notification on channel `relatives_alerts_v1` with an id in the app range
  (≥ `0x40000000`, ADR 0001 §3) derived from the alert id. Missing local data → generic
  text. `resolved` replaces the notification with the same id. Notifications use
  `VISIBILITY_PRIVATE` with a generic public version for the lock screen.
- **iOS (APNs):** `apns-push-type: alert`, priority 10, `aps.alert.loc-key` with a generic
  localized string under a **neutral key name** (`relatives_alert_1`, not `missed_dose`:
  Apple sees the key), `thread-id = p`, `apns-collapse-id = a` (a UUID, 36 bytes, under the
  64-byte limit, S4), `mutable-content: 1` so a Notification Service Extension can
  personalize the text later (follow-up). **No `m`** in APNs payloads: nothing uses it
  without the extension.
- **Expiry:** FCM `android.ttl`, APNs `apns-expiration` and RuStore `android.ttl` are set to
  `PUSH_STALE_AFTER_SECONDS` (2 h): an alarm about a dose two hours old is not delivered
  later. The outbox drops rows older than that too.

### 3. FCM (HTTP v1)

- `POST https://fcm.googleapis.com/v1/projects/{project_id}/messages:send`, OAuth2 bearer
  with scope `https://www.googleapis.com/auth/firebase.messaging` (S1). The access token
  comes from a service-account JWT (RS256, `pyjwt[crypto]`) exchanged at the token
  endpoint **hard-coded** as `https://oauth2.googleapis.com/token` (the JSON's `token_uri`
  is ignored), cached until shortly before expiry.
- One service account **per region**, with only `roles/firebasecloudmessaging.admin` (not
  the Admin SDK account); credentials from `FCM_SERVICE_ACCOUNT_JSON_FILE` (Docker secret)
  or the env variable. No Firebase Analytics or Crashlytics anywhere.
- `message.data` carries the payload (string values); `android.priority = HIGH` (S1:
  `NORMAL`/`HIGH`). **No `android.collapse_key`**: S1 notes at most four collapse keys can be
  active at once, and alerts must not collapse each other; dedupe happens on the device by
  notification id.
- Target field: `message.token`. S1 (revision 20260925) marks `token` **deprecated in
  favour of `fid`** (Firebase Installation ID) and says that during the transition `token`
  also accepts an FID; S12 shows `firebase_messaging` 17.0.0 adding "FID registration APIs".
  We store the opaque provider string and send it in `token`; whether the app registers an
  FCM token or an FID: **resolved in 3.9**, see "Implementation notes (3.9)".
- Error mapping (S2, S3): `UNREGISTERED` (404) → `INVALID_TOKEN`; `INVALID_ARGUMENT` (400)
  → `INVALID_TOKEN` only when the error refers to the registration token (it is also
  returned for payload problems, S3), else `FATAL`; `SENDER_ID_MISMATCH` (403) and
  `THIRD_PARTY_AUTH_ERROR` (401) → `FATAL` (configuration); `QUOTA_EXCEEDED` (429),
  `UNAVAILABLE` (503), `INTERNAL` (500) → `RETRY`, honouring `Retry-After` (S2).
- Token staleness (S3): FCM considers a registration stale after a month without
  connection and expired after 270 days on Android; the retention cron deletes tokens
  without success for 270 days.

### 4. APNs (HTTP/2 provider API, token-based)

- `POST /3/device/<token>` on `api.push.apple.com:443` (production) or
  `api.sandbox.push.apple.com:443` (development), HTTP/2 and TLS 1.2+ (S4). The token row
  stores `apns_environment` (`sandbox` | `production`) reported by the app's build, and the
  sender picks the host accordingly.
- Headers: `authorization: bearer <JWT>`, `apns-topic` = bundle id (`APNS_TOPIC`),
  `apns-push-type: alert`, `apns-priority: 10`, `apns-expiration`, `apns-collapse-id`,
  `apns-id` = a UUID generated per attempt and logged with the delivery id (S4). Payload ≤ 4096 bytes (S4).
- JWT: header `alg: ES256`, `kid` (10-char key id); claims `iss` (10-char team id), `iat`.
  Refreshed no more than once every 20 minutes and no less than once every 60 minutes; a
  token older than one hour gives `403 ExpiredProviderToken` (S6). The sender caches one
  JWT and renews it after 30–50 minutes. One `.p8` key **per region**
  (`APNS_PRIVATE_KEY_FILE` or env), so revoking one affects one region; keys may also be
  environment-scoped (S6).
- The token is in the request path, so httpx errors would contain it: transport errors are
  mapped to `RETRY` without `str(exc)` and logged as type and code only.
- Error mapping (S5): `410` (`Unregistered`, `ExpiredToken`), `400 BadDeviceToken` and
  `400 DeviceTokenNotForTopic` → `INVALID_TOKEN`; `403 ExpiredProviderToken` → renew the JWT
  and `RETRY`; other `403` (`InvalidProviderToken`, `BadCertificate…`, `Forbidden`) and
  `400 BadTopic`/`TopicDisallowed`/`PayloadTooLarge (413)` → `FATAL`; `429 TooManyRequests`,
  `500`, `503` → `RETRY`. Apple says not to retry `BadDeviceToken`,
  `DeviceTokenNotForTopic`, `Forbidden`, `ExpiredToken`, `Unregistered` or
  `PayloadTooLarge`, and that 5xx may be retried after 15 minutes with back-off (S5); the
  outbox back-off (30 s, 2 min, 10 min, 30 min) is bounded by the 2-hour staleness.
- `410` responses carry `timestamp` (ms since epoch) when the token stopped being valid
  (S5). A token re-registered by the app after that instant is kept: the delete is
  `WHERE id = :id AND updated_at <= :timestamp`.

### 5. RuStore Push

- `POST https://vkpns.rustore.ru/v1/projects/{project_id}/messages:send` with
  `Authorization: Bearer {service token}` (S7). Body `{"message": {"token", "data",
  "notification", "android": {"ttl", "notification"}}}`; S7 says only the listed fields are
  supported (no priority, no collapse key). We send `token`, `data` and `android.ttl` only
  (data-only message rendered by the app, as with FCM). Maximum message size 4096 bytes
  (S7).
- Errors (S7): the body carries `code`, `message`, `status`, and the HTTP status equals
  `code`. `NOT_FOUND` (404, "user push token is incorrect"; the docs' example is an expired
  token) → `INVALID_TOKEN`; `INVALID_ARGUMENT` (400) → `INVALID_TOKEN` when the message
  says the registration token is not valid (the docs' example), else `FATAL`;
  `PERMISSION_DENIED` ("service key is incorrect") → `FATAL`; `TOO_MANY_REQUESTS` and
  `INTERNAL` → `RETRY`. S7 shows codes 401 and 403 in its example without mapping them to
  statuses; we treat both as `FATAL` (configuration). **The exact 401/403 statuses and
  whether 429 carries `Retry-After` are to verify in 3.4 against a real project.**
- Not used: the universal endpoint `https://vkpns-universal.rustore.ru/v1/send` (S8), which
  fans one message out to RuStore, FCM, HMS and APNs with per-provider credentials. It
  would route Google and Apple traffic through a VK service as an extra processor of
  tokens; direct senders keep the third-party list minimal (§8).

### 6. Delivery (transactional outbox)

`push_outbox` rows are written in the same transaction as the alert or grant that causes
them (`dedupe_key` UNIQUE). `deliver_pushes` claims up to 200 pending rows with
`FOR UPDATE SKIP LOCKED` and **re-checks access in the claim query**, because access can
change between enqueue and send (revocation, leaving, narrowing, archive, deletion
request). A row is sent only if the recipient and the subject profile's owner are not
`pending_deletion`, the subject profile is live and not archived, the recipient still has
a role on it (owner or active grant), and, for `subject_medication_id`, that role may see
the medication's current privacy (`hidden` → full access only); otherwise it becomes
`dropped/access_changed`. A deletion request also marks pending rows about the user's
profiles `dropped` in its own transaction. It then sends concurrently with a bounded
semaphore and maps the
`SendResult`: `OK` → `sent`; `INVALID_TOKEN` → delete the token (cascades its pending
rows); `RETRY` → back-off; `FATAL` → `dropped` with the provider error code. After
`PUSH_MAX_ATTEMPTS` (5) or `PUSH_STALE_AFTER_SECONDS` (7200) the row is `dropped`. At least
once: a crash between send and mark may resend, which the device collapses by notification
id (and APNs by collapse id). Logs carry the delivery id, provider, status and error code,
never the token or payload; the worker's job wrapper logs failures as type and frames only
(ADR 0007 §6).

A provider without complete settings uses `DisabledPushSender` (rows `dropped` with
`provider_disabled`); in `prod`, a partially configured provider fails settings validation,
and **`REGION=eu` with any `RUSTORE_*` setting fails startup** (§8).

### 7. App side

- **Android without `google-services.json`.** The google-services Gradle plugin is not
  applied. `firebase_core` is initialized from Dart with
  `Firebase.initializeApp(options: FirebaseOptions(apiKey:, appId:, messagingSenderId:,
  projectId:))`, the four required constructor parameters (S11), read from dart-defines in
  `app-release.yml` (repo variables; they are non-secret identifiers, S14). Without them
  Firebase is not initialized and the device falls back to RuStore or none. On native
  Android, initializing with explicit `FirebaseOptions` removes the need for the Google
  services plugin and its JSON file (S13). **That `firebase_messaging` token retrieval and
  the background handler work on Android with Dart-only options and no plugin is to verify
  in 3.9** (S14 documents the `firebase_options.dart` path but does not state the plugin is
  unnecessary for Messaging): **resolved in 3.9**, see "Implementation notes (3.9)".
- **Versions.** `firebase_core` 5.0.0 and `firebase_messaging` 17.0.0 were published on
  2026-10-15 (S11, S12), one day before this ADR; 17.0.0 needs Android minSdk 24 (the app
  already uses 24) and Firebase iOS SDK 13 (not linked: no Firebase on iOS). The exact pin
  (17.x or the previous major, 16.7.0) is **decided in 3.9** after CI builds; the constraint
  is recorded in `app/pubspec.yaml` then.
- **RuStore.** Package `flutter_rustore_push` 7.2.0 (publisher `flutter.rustore.ru`, Dart
  SDK `>=2.18.5 <4.0.0`, S10). Native dependency `ru.rustore.sdk:pushclient:7.2.0` from the
  Maven repository `https://artifactory-external.vkpartner.ru/artifactory/maven`, added in
  `settings.gradle.kts` (S9). The project id is configured as AndroidManifest meta-data
  `ru.rustore.sdk.pushclient.project_id` (S9), filled from a Gradle placeholder
  `rustoreProjectId` (default empty). Delivery needs a distributor app (RuStore, or a VK app
  as fallback) installed, RuStore allowed to run in the background, and the app's signing
  fingerprint registered in the RuStore project, one project per signature/package (S9).
  S9 documents manifest-based initialization only and says the SDK must run in the main
  process; **behaviour of the SDK with an empty project id (the default build) and how to
  skip its initialization are to verify in 3.9** (see "Implementation notes (3.9)"). The Dart API used:
  `RustorePushClient.available()`, `getToken()`, `deleteToken()`, `onNewToken`,
  `onMessageReceived`, `onDeletedMessages`, `onMessageOpenedApp`, `onError` (S10).
- **iOS.** Native APNs registration in `AppDelegate.swift`; `aps-environment` entitlement
  added as a manual capability step before a signed build (like Time Sensitive in Phase 2).
  The channel reports the token hex string and the environment (`sandbox` for debug
  builds, `production` for release).

### 8. Third parties per region

| Processor | Data | RU | EU |
|---|---|---|---|
| Google (FCM) | push token / FID, opaque ids | yes | yes |
| Apple (APNs) | device token, opaque ids, generic localized key | yes | yes |
| VK (RuStore Push) | push token, opaque ids | yes | **never** (startup fails if configured) |

Tokens and opaque ids are personal data of the recipient; no medical data is sent. The
list goes into the Phase 5 privacy documents per region, including the cross-border
transfer notice for FCM and APNs under 152-FZ (listed for legal review, together with the
health-related metadata that a `missed` push at a given time represents for Google, Apple
and VK). Each region's backend holds its own credentials; nothing is shared across
regions.

## Implementation notes (3.4)

- **"To verify in 3.4" (RuStore statuses): still open.** Whether an invalid service key is
  answered with 401 or 403, and whether a 429 carries `Retry-After`, could not be checked: no
  RuStore project exists and the documentation site is not reachable from the build sandbox.
  `RuStoreSender` is built for either answer (401 and 403 are `FATAL`, `Retry-After` is
  honoured when present, any other unknown status falls back to 5xx/429 → `RETRY`, else
  `FATAL`) and its tests pin that behaviour; confirm against a real project with the manual
  checklist before launch. The `android.ttl` format (`"7200s"`, as in FCM) is assumed the same way.
- **Delivery with a lease.** The claim is one short transaction (`FOR UPDATE SKIP LOCKED`, access
  re-check, `attempts + 1`, `next_attempt_at` moved ahead by `PUSH_CLAIM_LEASE_SECONDS`), so no
  connection or row lock is held while talking to providers and a deletion request never waits
  for a send. A crash after the claim is retried when the lease ends and still counts as an
  attempt, so a poison row is dropped after `PUSH_MAX_ATTEMPTS`.
- **Database CHECKs on the payload** cover the values as well as the keys: `a p m g` must be
  UUIDs, `s` is `u`, `v` is `1` and `t` equals `kind`. A buggy writer cannot queue free text.
- **PostgreSQL regex repetition is limited to 255**, so the token format CHECK is
  `^[0-9a-f]{64,200}$` (APNs) or `^[A-Za-z0-9_:-]+$` plus a separate `char_length <= 4096`.
- **Logging.** `httpx` logs every request URL at INFO, and the APNs URL carries the device token:
  the `httpx`/`httpcore` loggers are set to WARNING when `app.push` is imported. The log scrubber
  redacts the key `code`, so delivery logs use `error_code`. ARQ prints the message and chain of a
  failed job, so the job wrapper raises a message-free `JobFailed` `from None`.
- **APNs `loc-key`s** are neutral and per kind: `relatives_alert_1` (`missed`), `_2` (`resolved`,
  replaces the missed notification through the shared collapse id), `_3` (`link_accepted`), `_4`
  (`link_restored`). The app (3.9) defines the localized strings.
- **A token the provider reports dead** is deleted only if it was not registered again after the
  provider's timestamp (APNs 410 `timestamp`); otherwise the row is retried.
- RuStore tokens are refused at registration outside `REGION=ru` (422).
- Retry-After longer than the back-off wins, capped at `PUSH_STALE_AFTER_SECONDS`.
- **Review fixes (PR #16).** The dead-token delete matches id, token value and provider, so a
  token the device registered meanwhile survives an answer about the old one. A payload that fails
  `PushPayload` validation is `dropped/bad_payload`, not a failed batch. One `deliver_pushes` run at a
  time (Redis `SET NX PX`, token-checked release, key `lock:push_delivery`); every recorded result is
  fenced by `attempts` and `status = 'pending'`; startup requires `PUSH_CLAIM_LEASE_SECONDS >
  ceil(batch / concurrency) x 3 x send timeout + 30 s`. A CHECK binds the payload's `p` and `m` to
  `subject_profile_id` and `subject_medication_id` (what the access check reads is what the device
  renders). Refresh-token reuse deletes the tokens of the revoked family's devices and a password
  reset deletes all of the account's tokens. `link_accepted` and `link_restored` are re-checked at send
  time: their grant `g` must still be active. The claim joins only tokens of the row's recipient.

### Accepted risks and open points

- **APNs `BadDeviceToken` on an environment mismatch.** A token registered with the wrong
  `apns_environment` (a sandbox build reporting `production`) gets `400 BadDeviceToken`, which maps to
  `INVALID_TOKEN` and deletes the token; the app registers it again at its next start with the right
  environment. Accepted: Apple does not distinguish a dead token from a wrong host.
- **FCM `m` for `anonymous` medications (decided in 3.5).** `m` lets the device look up a medication
  name locally; for an `anonymous` medication a projected relative must see time and status only.
  Decision: the detector omits `m` (and `subject_medication_id`, which the payload CHECK binds to it)
  from the pushes of projected recipients (`editor`, `viewer`) of `anonymous` medications, so the
  device renders a generic text; `shared` carries `m` for everyone, and full-access recipients
  (owner, guardian) get `m` for every privacy level (privacy protects from relatives, not from the
  people who run the profile). Consequence: such a row has no `subject_medication_id`, so the claim query re-checks `missed` and
  `resolved` rows through the alert instead (payload `a` -> the alert's medication): a projected
  recipient needs `shared` when the payload carries `m` and anything but `hidden` otherwise, and a
  `missed` also needs the grantee's `notify_missed`; else the row is `dropped/access_changed`. A
  narrowing to `hidden` or a shared -> anonymous change between enqueue and send therefore drops
  the viewer's row, while owner and guardians still get theirs.
- **The run lock is an optimisation.** A lock can expire under a stalled holder; correctness rests on
  the row claim and the fenced record, and delivery stays at least once.

## Implementation notes (3.9)

Items marked "to verify in 3.9" above, and what was found. Sources were read from the
published packages (pub.dev is not reachable from the authoring sandbox, so a throwaway CI
job dumped `flutter_rustore_push` 7.2.0 and the FlutterFire sources) and from the plugin
documentation. Nothing below was observed on a device with real credentials.

- **FCM token or FID: a token.** The app registers `FirebaseMessaging.getToken()` and the
  backend sends it in `message.token`. FID registration APIs exist only in
  `firebase_messaging` 17.x. Pin: `firebase_core` 4.15.0 and `firebase_messaging` 16.7.0
  (previous major, `^` ranges in `pubspec.yaml`, resolved by the scaffold bot). 17.0.0 and
  `firebase_core` 5.0.0 were published on 2026-10-15, two days before the ADR and four days
  before this milestone; they are not "a couple of weeks old". Moving to 17.x (and then to
  FIDs) is a follow-up that needs no backend change.
- **FlutterFire without the google-services plugin.** `Firebase.initializeApp(options:)` with
  the four `FirebaseOptions` from dart-defines works for the app isolate. The data-only
  handler of a terminated app runs in a new isolate and needs the *native* default app: the
  default `FirebaseInitProvider` creates it at process start from the string resources
  `google_app_id`, `google_api_key`, `gcm_defaultSenderId`, `project_id`. Gradle therefore
  writes exactly those four strings with `resValue`, only when all four defines are valid
  (`app/android/app/build.gradle.kts`), and `res/raw/keep.xml` keeps them from resource
  shrinking. Dart then finds the existing default app (`duplicate-app` is tolerated).
  Auto-init is off in the manifest (`firebase_messaging_auto_init_enabled=false`): no token
  is created until `FcmClient.start()` enables it, and `stop()` deletes the token and turns
  it off again. With no defines there are no resources, `FirebaseInitProvider` does nothing,
  and the app's own code never initializes Firebase (the libraries are linked and the native `FirebaseInitProvider` exists, but does nothing without the resources; `app.yml` and `app-release.yml` assert both cases in the
  merged manifest and the generated resources with `check_push_build.py`).
- **RuStore without a project id.** The plugin documents manifest meta-data
  `ru.rustore.sdk.pushclient.project_id` only; it has no Dart initialization call. The
  manifest therefore carries `<meta-data android:name="${rustoreProjectMetaName}"
  android:value="${rustoreProjectId}"/>`: with a project id the name is the SDK's and the value
  the id; without one the name is an inert `pillpal.rustore_project_id.unset` and the SDK
  finds no project. This is avoided by design, not observed: what the SDK does with a
  missing key is **still unverified** (the emulator job starts the app without one, which
  covers a crash at start). Only the RU region uses RuStore (`PILLPAL_REGION=ru`; no region
  means no RuStore). **With a project id the SDK is initialized from the manifest at process
  start, for every user, whether or not alerts are needed, and a lazy or manual init from
  `start()` could not be confirmed from the available documentation. RuStore must therefore
  not be enabled (leave `PILLPAL_RUSTORE_PROJECT_ID` unset) until a device check shows that
  the manifest initialization neither registers the device nor contacts RuStore for an
  account that needs no alerts.** This is an item of the manual checklist.
- **RuStore limitation (new).** `flutter_rustore_push` 7.2.0 forwards messages to Dart through
  callbacks of an attached engine; it has no background isolate entry point. A RuStore alert
  therefore renders while the app process is alive (foreground or recently backgrounded), not
  in a terminated app. FCM and APNs are not affected. Closing it needs a small native
  `RuStoreMessagingService` of our own (follow-up); until then the Family tab's day view is
  current after the next sync.
- **Maven repository, and an SDK stub.** `ru.rustore.sdk:pushclient` is served only by
  `https://artifactory-external.vkpartner.ru/artifactory/maven`, and that host answers 404 to
  everything (its root too) for GitHub-hosted runners (checked from a CI job; Maven Central
  has no such group). A plain dependency would break every CI build, so
  `app/android/rustore_sdk_stub` is a small Android library with the exact surface
  `flutter_rustore_push` 7.2.0 compiles against (`RuStorePushClient`, `RuStoreMessagingService`,
  `RemoteMessage`, `FeatureAvailabilityResult`, `Task`); `app/build.gradle.kts` substitutes it
  for the SDK unless a RuStore project id is configured (or CI sets
  `ORG_GRADLE_PROJECT_pillpalRustoreSdk=stub` to check a configured manifest). At run time the
  stub reports RuStore as unavailable. A build with a project id resolves the real SDK from
  the VK repository, declared in the root `build.gradle.kts` (`allprojects`, limited to the
  `ru.rustore` and `com.vk` groups; this project has no `dependencyResolutionManagement`, so
  not in `settings.gradle.kts`); `app-release.yml` fails early with an explanation when that
  repository is unreachable, so RuStore release builds need a runner or mirror in Russia.
  A new plugin version that uses more of the SDK breaks the stub compile (visible in CI) and
  the stub grows with it. Whether the plugin's own `buildscript` (AGP 8.6, Kotlin 2.0)
  works under this project's AGP 9.1 with `android.builtInKotlin=false` was shown by the
  configure phase (dependency resolution was reached); compiling the plugin against the real
  SDK is **verified only by a build with a project id**, not by CI.
- **Lock screen: a native public version.** Private visibility alone does not hide
  anything by default (an unlocked-secure-screen device shows the full text until the user
  chooses to hide sensitive content), so every alert carries a redacted public version
  (`Notification.setPublicVersion`): a neutral title and body that name nobody and nothing
  medical and are the same for every kind. No Flutter notification plugin can attach one, so
  Android alerts are posted by a small local plugin, `packages/pillpal_alerts` (Java, channel
  `pillpal/alerts`): `prepare`, `show`, `isShown`, a tap that reaches Dart as the opaque
  payload. A local plugin is registered in the background engine of a data-only push too,
  where `MainActivity` does not exist. `flutter_local_notifications` stays for the dose
  reminders only. The earlier text of this note ("the plugin has no public version, the
  platform's own redaction is what a lock screen shows") was wrong about the default and is
  withdrawn. The tap is a `PendingIntent` that launches the app with the payload in an extra;
  `AlertTapRouter` keeps a tap that arrives before the session is known and routes it once
  the user is signed in.
- **Firebase collects nothing else.** The manifest turns off Firebase analytics
  (`firebase_analytics_collection_deactivated`), the advertising id
  (`google_analytics_adid_collection_enabled=false`, and the `AD_ID` permission is removed
  from the merged manifest) and the delivery metrics export to BigQuery
  (`delivery_metrics_exported_to_big_query_enabled=false`); `check_push_build.py` asserts all
  of it in every build.
- **A token never outlives its need or its session.** `FcmClient.stop()` initializes Firebase
  first when settings exist, then deletes the token and disables auto-init, so a cold start can
  take back a token an earlier run created. The registration state is cleared only after the
  provider stopped; a provider that cannot stop keeps the state and the next trigger retries.
  When the session ends (explicit sign-out, a rejected refresh token, signing in as another
  account, account deletion) `PushService.sessionEnded()` stops every client of the platform
  whatever the stored state says (the state may be gone with the account's data); the server's
  row goes with the revoked session or fails as unregistered. A session-less reconcile (local
  data kept after a forced sign-out) also stops the provider, without a server call.
- **Background handler.** It parses strictly, opens the local database and shows nothing when no
  account is bound. Resolved alerts are remembered (`resolved_alerts.json`, ids only, 24 hours,
  200 entries) so a `missed` push that overtakes its `resolved` one is not shown.
- **Notification ids.** Relatives alerts use `0x40000000..0x4fffffff` (hash of the alert or grant
  id masked with `0x0fffffff`); the rest of the app range (ADR 0001 section 3) stays free.
- **Notifications off in the system.** The Family tab says so when a token is registered but
  the OS notification permission is denied (Android 13+, iOS).
- **iOS.** Our remote alerts complete their own `willPresent` and `didReceive` handlers (the
  plugin neither knows nor completes them), and the whole `userInfo` except `aps` goes to
  Dart, which accepts only the known keys, as on Android.
- **Provider choice.** Google Play services is detected natively (`pillpal/push`
  `gmsAvailable`, `PackageManager`, `<queries>` entry for the package), so the choice needs
  no Google library. iOS uses the raw token over the same channel; the environment is read
  from `embedded.mobileprovision` (`aps-environment` development means sandbox; no profile
  means production; the simulator is sandbox).
- **iOS texts.** `Localizable.strings` (en, ru) carry the four neutral keys with the generic
  texts of the Android fallback. Names are not personalized on iOS (no service extension).
  `aps-environment` is in `Runner.entitlements` and is dropped for the unsigned CI build
  like Associated Domains. The Push capability in the Apple account is a manual owner step.
- **Registration state.** `push_state` stores only the provider; the token is never stored
  or logged. A failed step leaves the state as it was, and start, resume, sync success, a
  scope or link write and an invite creation re-run the reconcile.
- **Unverified, for the manual checklist:** real FCM, APNs and RuStore delivery; the
  RuStore SDK with an empty project; killed-app FCM rendering on a device; the iOS banner in
  the foreground and the launch tap; the `aps-environment` detection on TestFlight builds.

## Consequences

- Backend dependencies: `httpx[http2]` (runtime), `pyjwt[crypto]`; senders are tested with
  `httpx.MockTransport` only (provider HTTP is a true external).
- All app workflows must stay green with no push credentials at all.
- Personalized iOS text needs a Notification Service Extension (follow-up); until then iOS
  relatives see a generic text, Android relatives see names from local projected data.
- A relative on Android without GMS and without RuStore gets no pushes; the app says so.

## Alternatives considered

- **Firebase on iOS too** (FCM → APNs): one more processor for iOS tokens and the Firebase
  iOS SDK in the build, for no gain; native APNs is a small channel.
- **Notification messages with text from the server:** would require the server to render
  names, i.e. medical data in the payload.
- **RuStore universal API for all providers:** see §5; extra processor for Google/Apple
  traffic.
- **A push SaaS** (OneSignal and similar): another third party holding tokens in both
  regions, and region localization becomes their problem.
