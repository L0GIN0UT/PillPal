# ADR 0009 — Invite links and deep links (Phase 3)

- Status: accepted
- Date: 2026-10-16 (revised after the PR #12 reviews)
- Scope: TZ §1 (regions), §2.5 ("Приглашение: ссылка + QR; приглашённый подтверждает"),
  §5 "Фаза 3" (deep links); backend `invites`, `app/api/links.py`; app `lib/src/links/`,
  Android manifest, iOS entitlements
- Related: ADR 0005 §3–§4 (grants and invite lifecycle), owner decision D6,
  `.claude/rules/security.md`, `.claude/rules/privacy.md` rules 2, 4 and 6

## Context

An owner invites a relative by sharing a link or showing a QR code; the relative opens it
in PillPal, sees who invites them to what, and confirms. The link is a bearer capability:
whoever holds it can link their account to the profile until it is used, revoked or
expired, and a guardian invite grants full access including hidden medications and dose
marking. It must not leak through server or proxy logs, referrers, or another app that
claims the same URL. Regions are separate deployments and must never link across (TZ §1).
The owner has not chosen a domain yet (D6).

## Decision

### 1. URL shape: token in the fragment

`https://{link_host}/i#<token>`

- The token is 256 bits (`secrets.token_urlsafe(32)`), returned once by
  `POST /v1/profiles/{profile_id}/invites` and stored only as `sha256(token)`; a fast hash
  suffices for a random 256-bit secret.
- The fragment is never sent in HTTP requests, so the token does not reach the server,
  proxies, CDN logs or `Referer` headers when the link is opened in a browser. Android App
  Links and iOS Universal Links hand the full URL, fragment included, to the app.
- The QR code encodes the same URL. The app sends the token in a JSON body to
  `POST /v1/invites/preview` and `/accept`, never in a URL.

### 2. Link host per region, config-driven (D6)

- Backend `PUBLIC_LINK_BASE_URL` per region; app `PILLPAL_LINK_HOSTS` (dart-define) and
  Gradle/Xcode placeholders.
- **Until the owner provides a domain, the hosts are placeholders under the reserved
  `.invalid` TLD:** `links-ru.pillpal.invalid`, `links-eu.pillpal.invalid`. They can never
  resolve. Non-blocking: invites, preview, accept, the paste fallback and the emulator
  journey (explicit package) all work; only OS link verification on real devices waits for
  the domain (manual checklist, 3.10).
- Proposal for later: serve `/i` and `/.well-known/*` from the regional API host; changing
  it is configuration only.

### 3. Verified app links; no custom scheme in any build

- Backend serves from Settings `GET /.well-known/assetlinks.json` (`ANDROID_PACKAGE_NAME`,
  `ANDROID_CERT_SHA256S`: upload key and Play app-signing key) and
  `GET /.well-known/apple-app-site-association` (`APPLE_TEAM_ID`, `IOS_BUNDLE_ID`, path
  `/i`): `application/json`, no redirects, 404 when unset. In `prod` the fingerprints are
  format-validated and the Android debug certificate is rejected.
- `GET /i` is a static landing page that never contains or reads the token, loads no
  third-party resources, and sends `Cache-Control: no-store`, `Referrer-Policy: no-referrer`,
  `X-Content-Type-Options: nosniff` and a strict CSP with `frame-ancestors 'none'`.
- Android: `intent-filter android:autoVerify="true"`, scheme `https`, hosts from Gradle
  `manifestPlaceholders`, `pathPrefix="/i"`; Flutter's built-in deep linking is disabled in
  favour of `app_links`. `app-release.yml` checks the merged manifest for VIEW filters with
  a scheme other than `https`.
- iOS: `com.apple.developer.associated-domains` = `applinks:<host>` per region from
  `ios/Flutter/Links.xcconfig` (manual capability step before a signed build).
- **No custom URL scheme in any build, debug included**: any app can register `pillpal://`
  and receive tokens.
- **Never accept automatically.** An explicit intent from any app reaches the activity
  without App Links verification, so the confirmation screen is the real protection. For
  `guardian` it shows a prominent warning ("full access, including hidden medications and
  marking doses").
- Fallback: "Paste invite link" in the Family tab.

### 4. Lifecycle and errors

- **Create** (owner of a live, non-archived profile): body `{id, role, disclosure_version}`
  with a client UUID so a lost response can be retried. Before creating, the app shows what
  the relative will see — medications by privacy level (course dates for `anonymous`), the
  self profile's time zone (follows the phone) and the last sync hour (D5) — and sends the
  version of that screen, later copied to the grant (ADR 0005 §3).
  - TTL: **24 h for `guardian`**, 7 days otherwise (`GUARDIAN_INVITE_TTL_SECONDS`,
    `INVITE_TTL_SECONDS`); at most 5 active per profile (`409 too_many_invites`); `guardian`
    only on managed profiles; archived profiles refuse (`409 read_only`).
  - A replay of the same id gives `409 already_exists` (the token cannot be shown twice);
    the client **deletes** that orphaned invite and creates a new one, so it does not hold
    a slot of the cap for 7 days.
- **Preview:** `{inviter_display_name, profile_display_name, profile_kind, role, expires_at}`.
- **Accept** (same transaction, invite row locked):
  - expired → `invite_expired`; revoked or unknown → `invite_invalid`; own profile →
    `invite_own_profile`; limits → `relatives_limit_reached` / `too_many_scopes`;
  - an existing grant of the caller on the profile (UNIQUE conflict) → `already_linked`,
    **the invite is not consumed**;
  - otherwise create the grant (role and `disclosure_version` from the invite), consume
    the invite, enqueue `link_accepted` to the owner;
  - **replay** (invite consumed by the same caller): return the grant **only if it still
    exists**; otherwise `invite_used`. A consumed invite never re-creates a grant, so a
    revoked relative cannot come back with the old link. Consumed by someone else →
    `invite_used`.
- Distinct codes reveal nothing to someone without the token, which is the capability.
- Rate limits per user and IP on preview and accept. The limiter is fail-open when Redis is
  down; acceptable for 256-bit tokens, recorded here.
- The owner sees a new link through the `link_accepted` push and, independent of push, a
  "new relative" banner in the Family tab.
- **Retention:** `consumed_by_user_id` is set to NULL after `INVITE_REPLAY_WINDOW_SECONDS`
  (24 h; replays later get `invite_used`), and invites are deleted 30 days after expiry,
  consumption or revocation. No history of who accepted what is kept beyond the grant.

### 5. Regions

- Invites and grants live in one regional database; a token from one region does not exist
  in the other (`invite_invalid`).
- The app refuses a link whose host belongs to the other region with "invite from another
  region" (TZ §1), before any request.

## Consequences

- No token appears in any URL the server sees, in logs or in referrers.
- A leaked guardian link is usable for at most 24 h, the accept screen warns, and the owner
  sees the new relative even without push.
- Until D6 is decided, links on real devices open the browser; testers use the paste
  fallback or `adb am start` with the package.
- Rotating the Play app-signing key or adding a build flavour means updating
  `ANDROID_CERT_SHA256S`.

## Alternatives considered

- **Token in the path or query:** reaches server and proxy logs and referrers.
- **Custom scheme** (`pillpal://invite/<token>`): hijackable by any app on Android.
- **Owner approval of every guardian acceptance** (pending grant): stronger, but needs the
  owner's device at hand; the 24 h TTL, the warning and the banner were preferred for now.
- **Short numeric codes:** brute-forceable within the TTL unless heavily rate-limited.
- **Firebase Dynamic Links:** deprecated and shut down by Google, and it would be another
  third party in both regions.
- **A real domain now:** the owner has not chosen one (D6).
