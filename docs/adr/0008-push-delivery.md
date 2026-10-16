# ADR 0008 — Push delivery: FCM, APNs, RuStore (Phase 3)

- Status: accepted
- Date: 2026-10-16
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
the server sends to every token of a recipient. Logout deletes the device's token; an
account deletion request deletes all of them (ADR 0010).

### 2. Payload: ids only, rendered on the device

`PushPayload` (strict Pydantic, `extra="forbid"`) is the only way to build a payload:
`v` (1), `t` (`missed` | `resolved` | `link_accepted`), `a` alert id, `p` subject profile id,
`m` medication id, `g` grant id, `s` (`u` = unconfirmed). A DB CHECK on
`push_outbox.payload` allows only these keys. No names, doses, times or occurrence keys
(the key encodes the schedule time) go over the wire.

- **Android (FCM, RuStore):** data-only, high-priority messages. A background handler with
  no network reads the subject profile's name and, for `shared` medications with "hide
  names" off, the medication name from local drift (already projected, ADR 0006), and
  shows a local notification on channel `relatives_alerts_v1` with an id in the app range
  (≥ `0x40000000`, ADR 0001 §3) derived from the alert id. Missing local data → generic
  text. `resolved` replaces the notification with the same id.
- **iOS (APNs):** `apns-push-type: alert`, priority 10, `aps.alert.loc-key` with a generic
  localized string, `thread-id = p`, `apns-collapse-id = a` (a UUID, 36 bytes, under the
  64-byte limit, S4), `mutable-content: 1` so a Notification Service Extension can
  personalize the text later (follow-up).
- **Expiry:** FCM `android.ttl`, APNs `apns-expiration` and RuStore `android.ttl` are set to
  `PUSH_STALE_AFTER_SECONDS` (2 h): an alarm about a dose two hours old is not delivered
  later. The outbox drops rows older than that too.

### 3. FCM (HTTP v1)

- `POST https://fcm.googleapis.com/v1/projects/{project_id}/messages:send`, OAuth2 bearer
  with scope `https://www.googleapis.com/auth/firebase.messaging` (S1). The access token
  comes from a service-account JWT (RS256, `pyjwt[crypto]`) exchanged at Google's token
  endpoint and cached until shortly before expiry.
- `message.data` carries the payload (string values); `android.priority = HIGH` (S1:
  `NORMAL`/`HIGH`). **No `android.collapse_key`**: S1 notes at most four collapse keys can be
  active at once, and alerts must not collapse each other; dedupe happens on the device by
  notification id.
- Target field: `message.token`. S1 (revision 20260925) marks `token` **deprecated in
  favour of `fid`** (Firebase Installation ID) and says that during the transition `token`
  also accepts an FID; S12 shows `firebase_messaging` 17.0.0 adding "FID registration APIs".
  We store the opaque provider string and send it in `token`; whether the app registers an
  FCM token or an FID is **to verify in 3.9**.
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
  JWT and renews it after 30–50 minutes. Keys may be environment-scoped (S6): the settings
  allow one key; a second key per environment is a config change if needed.
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
`FOR UPDATE SKIP LOCKED`, sends concurrently with a bounded semaphore, and maps the
`SendResult`: `OK` → `sent`; `INVALID_TOKEN` → delete the token (cascades its pending
rows); `RETRY` → back-off; `FATAL` → `dropped` with the provider error code. After
`PUSH_MAX_ATTEMPTS` (5) or `PUSH_STALE_AFTER_SECONDS` (7200) the row is `dropped`. At least
once: a crash between send and mark may resend, which the device collapses by notification
id (and APNs by collapse id). Logs carry the delivery id, provider, status and error code,
never the token or payload.

A provider without complete settings uses `DisabledPushSender` (rows `dropped` with
`provider_disabled`); in `prod`, a partially configured provider fails settings validation.

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
  unnecessary for Messaging).
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
  skip its initialization are to verify in 3.9.** The Dart API used:
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
| VK (RuStore Push) | push token, opaque ids | yes | disabled by default (config) |

Tokens and opaque ids are personal data of the recipient; no medical data is sent. The
list goes into the Phase 5 privacy documents per region, including the cross-border
transfer notice for FCM and APNs under 152-FZ. Each region's backend holds its own
credentials; nothing is shared across regions.

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
