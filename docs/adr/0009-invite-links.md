# ADR 0009 — Invite links and deep links (Phase 3)

- Status: accepted
- Date: 2026-10-16
- Scope: TZ §1 (regions), §2.5 ("Приглашение: ссылка + QR; приглашённый подтверждает"),
  §5 "Фаза 3" (deep links); backend `invites`, `app/api/links.py`; app `lib/src/links/`,
  Android manifest, iOS entitlements
- Related: ADR 0005 §4 (invite lifecycle), owner decision D6, `.claude/rules/security.md`,
  `.claude/rules/privacy.md` rules 2 and 4

## Context

An owner invites a relative by sharing a link or showing a QR code; the relative opens it
in PillPal, sees who invites them to what, and confirms. The link is a bearer capability:
whoever holds it can link their account to the profile until it is used, revoked or
expired. It must not leak through server or proxy logs, referrers, or another app that
claims the same URL. Regions are separate deployments and must never link across (TZ §1).
The owner has not chosen a domain yet (D6).

## Decision

### 1. URL shape: token in the fragment

`https://{link_host}/i#<token>`

- The token is 256 bits (`secrets.token_urlsafe(32)`), returned once by
  `POST /v1/profiles/{profile_id}/invites` and stored only as `sha256(token)`; a fast hash
  suffices for a random 256-bit secret.
- The fragment is never sent in HTTP requests, so the token does not reach the server,
  reverse proxies, CDN logs or `Referer` headers when the link is opened in a browser.
  Android App Links and iOS Universal Links hand the full URL, fragment included, to the
  app.
- The QR code encodes the same URL.
- The app sends the token in a JSON body to `POST /v1/invites/preview` and
  `POST /v1/invites/accept`, never in a URL. Access logs use route templates
  (`observability.py`) anyway.

### 2. Link host per region, config-driven (D6)

- Backend `PUBLIC_LINK_BASE_URL` per region; app `PILLPAL_LINK_HOSTS` (dart-define, both
  regions' hosts) and Gradle/Xcode placeholders.
- **Until the owner provides a domain, the hosts are placeholders under the reserved
  `.invalid` TLD:** `links-ru.pillpal.invalid` and `links-eu.pillpal.invalid`. They can never
  resolve, so nothing can be served there by accident. This is non-blocking: invites,
  preview, accept, the in-app paste fallback and the emulator journey (which starts the app
  with an explicit package) all work with the placeholder; only OS link verification on
  real devices needs the real domain (manual checklist, 3.10).
- Proposal for later: serve `/i` and `/.well-known/*` from the regional API host. Changing
  the host is a config change in the backend and the app build, not a code change.

### 3. Verified app links, no custom scheme in release

- Backend serves, from Settings, `GET /.well-known/assetlinks.json` (`ANDROID_PACKAGE_NAME`,
  `ANDROID_CERT_SHA256S`: upload key and Play app-signing key) and
  `GET /.well-known/apple-app-site-association` (`APPLE_TEAM_ID`, `IOS_BUNDLE_ID`, path
  `/i`); both 404 when unset.
- `GET /i` is a static landing page ("open in PillPal" / store links): it never contains
  or reads the token, with `Cache-Control: no-store`, `Referrer-Policy: no-referrer` and a
  strict CSP.
- Android: `intent-filter android:autoVerify="true"`, scheme `https`, hosts from Gradle
  `manifestPlaceholders`, `pathPrefix="/i"`; Flutter's built-in deep linking is disabled in
  favour of `app_links`.
- iOS: `com.apple.developer.associated-domains` = `applinks:<host>` per region from
  `ios/Flutter/Links.xcconfig`; a manual capability step before a signed build.
- **No custom URL scheme in release builds**: any app can register `pillpal://` and would
  receive the tokens. A verified `https` link is bound to the domain's published
  association files.
- Fallback: "Paste invite link" in the Family tab, for unverified domains, other apps that
  strip links, or desktop-shared links.

### 4. Lifecycle and errors

- Create: owner of a live, non-archived profile; body `{id, role}` with a client UUID so a
  lost response can be retried (`409 already_exists` on replay; the client then creates a
  new invite, since the token cannot be shown twice). `guardian` only on managed profiles.
  TTL 7 days (`INVITE_TTL_SECONDS`), at most 5 active per profile (`409 too_many_invites`).
  Archived profiles refuse invites (`409 read_only`, ADR 0005 §5).
- Preview: `{inviter_display_name, profile_display_name, profile_kind, role, expires_at}`.
- Accept: locks the invite row, creates the grant, consumes the invite, and enqueues a
  `link_accepted` push to the owner. A replay by the same user returns the existing grant.
- Codes: `invite_invalid` (unknown or revoked, including invites revoked by the owner's
  account deletion request, ADR 0010), `invite_expired`, `invite_used`,
  `invite_own_profile`, `already_linked`, `relatives_limit_reached` (soft limits on).
  Because the token is the capability, distinct codes reveal nothing to someone without it.
- Rate limits per user and IP on preview and accept.
- Retention: invites are deleted 30 days after they expire, are consumed or are revoked.

### 5. Regions

- Invites and grants live in one regional database, so a token from one region does not
  exist in the other and is `invite_invalid` there.
- The app knows which host belongs to which region and refuses a link whose host is the
  other region's with "invite from another region" (TZ §1), before any request.

## Consequences

- No token appears in any URL the server sees, in logs or in referrers.
- Until D6 is decided, tapping a link on a real device opens the browser (domain not
  verified); testers use the paste fallback or `adb am start` with the package.
- Rotating the Play app-signing key or adding a build flavour means updating
  `ANDROID_CERT_SHA256S`.

## Alternatives considered

- **Token in the path or query** (`/i/<token>`, `?t=`): reaches server and proxy logs and
  referrers.
- **Custom scheme** (`pillpal://invite/<token>`): hijackable by any app on Android.
- **Short numeric codes** typed by hand: brute-forceable within the TTL unless heavily
  rate-limited, and a worse experience than QR.
- **Firebase Dynamic Links:** deprecated and shut down by Google, and it would be another
  third party in both regions.
- **A real domain now:** the owner has not chosen one (D6); a placeholder keeps the work
  unblocked.
