# ADR 0017 — OAuth identities and account linking (Phase 5)

- Status: Accepted (owner decisions 2026-11-10)
- Date: 2026-11-10
- Scope: TZ §1 ("Вход"), §3, §5 "Фаза 5"; backend migration `0022_auth_identities`;
  `app/settings_oauth.py`, `app/domain/auth_providers.py`,
  `app/oauth/{base,fake,jwks,apple,google,vk_id,yandex_id,registry}.py`, services
  `identities`, `oauth_sign_in`; router `oauth`; `DELETE /v1/me`; `api/auth.py`
  (`UserOut.has_password`); `observability.py`
- Related: owner decisions Q1 and Q7 (`docs/phase5-plan.md`), ADR 0010 (deletion, restore
  ticket, `_offer_restore`), ADR 0016 (consents at sign-up, `DATA_ENCRYPTION_KEY`), ADR 0008
  §8 (third parties per region), `.claude/rules/security.md`, `.claude/rules/privacy.md` rules
  2–4, 8
- Supersedes: the provider line of the Phase 4 appendix (`docs/phase4-plan.md`, "OAuth
  framework": VK ID and Yandex ID on iOS, Apple in RU)

## Context

TZ §1 fixes sign-in per region and platform: RU-Android has e-mail, VK ID and Yandex ID;
RU-iOS has e-mail only; the rest of the world has e-mail, Apple and Google. Today the only
method is e-mail + password (Argon2id, verified e-mail, refresh rotation). Client
registrations with the providers do not exist yet, so the framework must be fully testable
with fakes and stay inert until client ids are configured.

The risks are account takeover through a provider asserting an e-mail, enumeration of
registered addresses, token replay, cross-region leakage, and losing the ADR 0010 guarantees
(re-auth before deletion, restore needs a mailed code).

## Decision

### 1. Provider × region × platform matrix (Q1)

| Region | Provider | Platforms | Assertion |
|---|---|---|---|
| `ru` | `vk_id` | android | code exchange with PKCE |
| `ru` | `yandex_id` | android | code exchange with PKCE |
| `eu` | `apple` | ios | ID token (+ authorization code) |
| `eu` | `google` | android, ios | ID token |

- The matrix is pure data in `domain/auth_providers.py`. RU-iOS is e-mail only.
- Every environment refuses Apple/Google settings in RU and VK/Yandex settings in EU at
  startup. Strict environments refuse partial provider configuration (client id without its
  secret or key, and the reverse).
- A provider is available only when `FEATURE_OAUTH=true`, it is configured and the matrix
  allows `(region, platform)`. `GET /v1/auth/providers?platform=` lists the available ones.
  Any other provider, platform or region → 404 on every OAuth route.
- `oauth/fake.py` is test-only and refused outside dev/test.
- Every e-mail-capable iOS configuration offers Sign in with Apple wherever a third-party
  login exists (EU), and RU-iOS has none; this matches App Store Guideline 4.8 (to confirm at
  review).

### 2. `auth_identities`

`auth_identities (id, user_id fk CASCADE, provider CHECK IN (apple, google, vk_id,
yandex_id), subject 1..255, email_at_link null, created_at, last_used_at,
provider_refresh_token_enc bytea null, UNIQUE (provider, subject))`:
- server-generated id; personal; exported as rows without `*_enc`; erased with the account;
- the subject is the provider's stable id and never the e-mail. It is never returned by
  `GET /v1/me/identities` and never logged.

### 3. Verification

- **Apple and Google (5.8):**
  - JWKS fetched and cached, refreshed once on an unknown `kid`;
  - algorithms pinned (RS256/ES256); `none` and HS* refused;
  - `iss`, `aud` (our client ids), `exp`/`iat`, and `nonce == sha256(raw nonce)` sent by the
    client checked; the e-mail counts only with `email_verified`;
  - used tokens are kept in Redis `on:` (hashed key) until their `exp`, so a token is
    accepted once.
- **VK ID and Yandex ID (5.9):**
  - server-side code exchange with PKCE; client secrets have `_FILE` variants;
  - a VK e-mail counts as verified only if the provider documentation says so; otherwise the
    §5 fallback applies;
  - a timeout is 503 `provider_unreachable` (`OAUTH_HTTP_TIMEOUT_SECONDS=10`), and a provider
    error is 401.
- A bad or replayed assertion → 401 `invalid_provider_token`.

### 4. Sign-in and no auto-merge

`POST /v1/auth/oauth/{provider}/sign-in`:
- **Known `(provider, subject)`** → 200 token pair. If the account is pending deletion → 403
  `account_pending_deletion` through `_offer_restore` (restore ticket + mailed code,
  ADR 0010 §2). The provider assertion alone never restores.
- **Verified e-mail of an existing account, unknown identity** → 409 `oauth_account_exists`.
  **No automatic merge**: a provider's claim about an address is not proof that the person
  controls the PillPal account. The user signs in with the existing method and links the
  provider in settings (§6). The answer appears only after a valid assertion with a
  provider-verified e-mail, so it is not an open enumeration oracle.
- **Otherwise** → 409 `oauth_signup_required` with a `signup_ticket`. The ticket is random,
  single-use and stored in Redis under `ot:` + sha256(ticket) for
  `OAUTH_SIGNUP_TICKET_TTL_SECONDS=600`. It carries the verified provider identity (exact
  contents decided in milestone 5.6), so sign-up never re-trusts client input about the
  subject or e-mail.

### 5. Sign-up and the e-mail fallback (Q7)

`POST /v1/auth/oauth/sign-up {signup_ticket, region, locale, timezone, display_name?,
consents, email?}`:
- the ticket is consumed first. Consents are required and validated as in ADR 0016 §3, with
  source `oauth_signup`;
- **verified provider e-mail** → 201: account, `self` profile, identity, token pair;
- **no verified e-mail** (VK ID unless proven otherwise) → `email` is required. Answer 202
  `VerificationSent` with a mailed code; the flow finishes through the existing
  `verify-email`. No account is usable and no token is issued without a verified e-mail. How
  the pending identity is held until verification is decided in milestone 5.6;
- **the address belongs to an existing account** → the same 202, plus a notice mail to that
  address (no enumeration, as for registration in ADR 0010 §3). No identity is attached.

### 6. Account management (5.7)

- `GET /v1/me/identities` lists provider, `email_at_link` and timestamps (no subject).
- `POST /v1/me/identities` links a verified assertion to the signed-in account: 201, replay
  200; an identity held by another account → 409 `identity_in_use`.
- `DELETE /v1/me/identities/{id}`: 204; a foreign id → 404; removing the last sign-in method
  → 409 `last_sign_in_method`. A password counts as a method only if `has_password`.

### 7. Passwordless accounts

- An OAuth-only account stores an unusable sentinel in `users.password_hash`, so the `users`
  schema does not change. `PasswordHasher.verify` treats the sentinel like an unknown user:
  it verifies against the dummy hash in constant time and answers `invalid_credentials`.
- `UserOut.has_password` tells the app which re-auth form to show. Password reset (mailed
  code) sets a real password.

### 8. Re-auth for deletion

`DELETE /v1/me` accepts `{password}` (unchanged) or `{reauth: {provider, platform,
assertion}}`. The assertion must belong to a linked identity and be fresh: `iat` within
`OAUTH_REAUTH_MAX_AGE_SECONDS=300`, and not replayed (`on:`). Everything after the check is
ADR 0010 §1 unchanged.

### 9. Apple token revocation on deletion

- At sign-up or link, Apple's authorization code is exchanged server-side with an ES256
  client secret. The refresh token is stored encrypted in `provider_refresh_token_enc` with
  `HKDF(DATA_ENCRYPTION_KEY, info="oauth-refresh/v1")` (salt and the exact format decided in
  milestone 5.8).
- After the deletion request **commits**, the backend calls Apple's revoke endpoint (best
  effort, one retry) and clears the column. A revoke failure never fails or rolls back the
  deletion. The account is erased within the grace period either way.
- After a restore, the next Apple sign-in authorizes again. Whether a new refresh token is
  stored then is decided in 5.8.

### 10. Secrets in logs and Sentry

ID tokens, authorization codes, PKCE verifiers, nonces, signup tickets, client secrets and
provider refresh tokens join `SENSITIVE_KEYS` and `SENTRY_SECRET_KEYS`. Logs carry the
provider name, route template, status and opaque user ids only. Tests assert that no token or
code appears in logs.

### 11. Third parties per region

| Processor | Data | RU | EU |
|---|---|---|---|
| VK (VK ID) | provider subject, e-mail if granted, tokens during exchange | yes (Android) | **never** (startup fails) |
| Yandex (Yandex ID) | same | yes (Android) | **never** (startup fails) |
| Apple (Sign in with Apple) | subject, e-mail or relay e-mail, refresh token (encrypted at rest) | **never** | yes (iOS) |
| Google (Sign-In) | subject, verified e-mail | **never** | yes (Android, iOS) |

No medical data goes to any provider. Each region holds its own client registrations and
secrets, so RU sign-in has no cross-border provider. The list goes into the Phase 5 privacy
documents per region (as ADR 0008 §8).

## Consequences

Positive:
- The matrix in TZ §1 is enforced in one place, and misconfiguration fails at startup.
- No path turns a provider claim into access to an existing account.
- Deletion keeps its re-auth and restore keeps its mailed code. Apple's deletion requirement
  is met without blocking the deletion.
- Everything is testable with `httpx.MockTransport` and locally generated keys.

Negative:
- Users who registered by e-mail and later tap "Sign in with Google" hit a 409 and must link
  manually. That is the price of no auto-merge.
- `DATA_ENCRYPTION_KEY` becomes required wherever Apple is configured (EU), not only for the
  export.
- The VK e-mail fallback adds a third sign-up path to test.

Follow-ups:
- 5.6–5.9. App buttons and SDKs once client ids exist (not in this slice).
- Confirm the VK e-mail verification semantics against the provider documentation (5.9).
- Confirm Guideline 4.8 at the first iOS review.

## Alternatives considered

- **Auto-merge on a matching verified e-mail.** The classic takeover vector (a provider or a
  mailbox at a provider asserting an address); rejected.
- **Create the account at sign-in without a ticket.** Skips consents and the e-mail
  fallback; rejected.
- **Nullable `password_hash`.** A migration on `users`, plus every verify path must handle
  null and risk timing differences; rejected for the sentinel.
- **Client-side Apple revocation only.** Not possible after the app is deleted, and Apple
  expects server-side revocation; rejected.
- **One global provider configuration for both regions.** Breaks region isolation; rejected.
- **VK ID / Yandex ID on iOS and Apple in RU** (Phase 4 appendix). Contradicts TZ §1;
  superseded by Q1.
