# ADR 0018 — Entitlements, promo codes and payments (Phase 5)

- Status: Accepted (owner decisions 2026-11-10); amended 2026-11-10 after the privacy and
  security review (see the Review log in `docs/phase5-plan.md`)
- Date: 2026-11-10
- Scope: TZ §1 ("Монетизация", "Реклама", "Публикация"), §5 "Фаза 5", §6 ("Оплата"); backend
  migrations `0018_entitlements`, `0019_admin_audit`, `0020_promo_codes`, `0023_purchases`;
  `app/settings_entitlements.py`, `app/settings_payments.py`, `app/domain/entitlements.py`,
  `app/admin/`, `app/payments/{base,storekit,rustore,play,registry}.py`, services
  `entitlements`, `promo`, `purchases`; routers `me_entitlements`, `purchases`; `invites.py`
  (soft limits); `observability.py`; app A2
- Related: owner decisions of 2026-10-22 (Phase 4 appendix: `ads_removed` per account, promo
  codes) and Q2 (`docs/phase5-plan.md`), ADR 0005 (relatives and managed profiles), ADR 0016
  §9 (keyring and key separation), `.claude/rules/security.md`, `.claude/rules/privacy.md`
  rules 1, 2, 8

## Context

The core is free. Ads are removed by a one-time purchase, and soft limits (about 3 relatives,
the number of PDF reports) switch on together with payments, all behind flags (TZ §1). The
developer is a private person and store billing is not available yet (TZ §6). The owner wants
an ads-free state that works without payments: promo codes and direct grants. Everything must
work with `FEATURE_PAYMENTS=false`, be testable without store accounts, and never mix
monetisation with medical context.

## Decision

### 1. Kinds, sources and scope

Table `entitlements (id, user_id fk CASCADE, kind, source, source_ref uuid null, granted_at,
expires_at null, revoked_at null)`:
- `kind` CHECK IN (`ads_removed`, `limits_lifted`); `source` CHECK IN (`purchase`, `promo`,
  `admin_grant`); CHECK `expires_at > granted_at`;
- server-generated id, personal, exported as rows, erased with the account.
- `source_ref` points at the originating purchase or redemption (exact target per source
  decided in 5.3, 5.4 and 5.10).
- **Per account.** An entitlement covers the account and its managed profiles while that
  account is signed in. It is **not inherited** by relatives, viewers, editors or
  co-guardians, who have their own accounts and entitlements. A profile transferred to a
  co-guardian (D1) does not carry the former owner's entitlement.
- What each kind grants:
  - **purchase:** the one-time remove-ads product grants both `ads_removed` and
    `limits_lifted` (Q2) through the `PAYMENTS_PRODUCTS` mapping;
  - **promo code:** the one kind set at creation;
  - **admin grant:** the kind given on the command line.

### 2. Effective state

- Pure `domain/entitlements.py::effective(rows, now)`. A kind is effective when at least one
  row of that kind has `revoked_at IS NULL` and (`expires_at IS NULL` or `now < expires_at`).
  Rows are never deleted to revoke; `revoked_at` is set. A table test covers the boundaries.
- `GET /v1/me/entitlements` → `{ads_removed, limits_lifted, items, server_time}` with
  `Cache-Control: private, no-store`. It works with `FEATURE_PAYMENTS=false`. From 5.10 it
  also returns `app_account_token` (§6).
- **App (A2):**
  - caches the result per account, refreshed on sign-in and daily;
  - on failure keeps the last value for 14 days; clears it on sign-out;
  - `adsAllowedProvider(screen)` is pure and uses an **allowlist of named non-medical
    screens**: `settings` and `about`. Every other screen is false, including the Family and
    day views of relatives, reports and PDF, scan, consent, export and privacy settings. It is
    also false with `ads_removed`. §8 and the 5.12 validator use the same list;
  - no ad SDK in this slice.

### 3. Promo codes

- Table `promo_codes (id, code_digest UNIQUE, label 1..64, kind, grant_days null,
  max_activations >= 1, activations 0..max_activations, expires_at null, disabled_at null,
  created_at)`, classified `system`. The label is a campaign name and must hold no personal
  data.
- Table `promo_redemptions (code_id, user_id fk CASCADE, redeemed_at, entitlement_id, PK
  (code_id, user_id))`: personal, exported, erased.
- **Generation.** Characters come from `secrets` over `23456789ABCDEFGHJKMNPQRSTUVWXYZ` (31
  symbols, no 0/O/1/I/L). `PROMO_CODE_LENGTH=20` (about 99 bits), minimum 16 (about 79
  bits). Codes are printed once, grouped for reading.
- **Normalisation.** Spaces and hyphens are removed. Every remaining character must be ASCII
  and, **before any case mapping**, one of the alphabet's symbols or its ASCII lowercase form.
  Anything else is an invalid code. Only then is the input uppercased. This keeps non-ASCII
  letters that uppercase to ASCII from matching.
- **Storage.** `HMAC-SHA256(PROMO_CODE_HMAC_KEY, normalized)`. Lookup is by the UNIQUE
  `code_digest`; the digest is a keyed hash, so an equality lookup leaks nothing useful. The
  plaintext is never stored, listed or logged.
- `PROMO_CODE_HMAC_KEY` rules:
  - 32 random bytes, base64-encoded; decoded and length-checked at startup (the same rule as
    the keyring keys, ADR 0016 §9);
  - must differ from `JWT_SECRET` and from every `DATA_ENCRYPTION_KEYS` key;
  - required in strict environments when `FEATURE_PROMO_CODES=true`;
  - a code of one region fails in the other.
- `grant_days` sets the entitlement's `expires_at = redeemed_at + grant_days`; null means no
  expiry.

### 4. Redeem

`POST /v1/me/promo/redeem {code ≤ 64}` behind `FEATURE_PROMO_CODES=false` (403
`feature_disabled`).

Order of checks, cheapest and most protective first:
1. per-user rate limit;
2. per-IP bucket;
3. daily lockout: `PROMO_MAX_FAILED_PER_DAY=5` failures → 429 `promo_locked` with
   `Retry-After`;
4. global breaker, **alert-only**. More than 200 failures in 3600 s, counted globally, emits
   the metric and the log code `promo_breaker_tripped`. For 900 s it blocks only callers who
   already have at least one failure today: they get 503 `promo_unavailable`. Other callers
   are not blocked by the breaker;
5. lookup by digest.

- **Fail closed:** if Redis (limits, lockout, breaker counters) is unavailable, the answer is
  503 `promo_unavailable`, never an unchecked lookup.
- **Failure counting:** each failure runs `INCR` and then `EXPIRE` on its counter **before**
  the response is sent.
- **One transaction, explicit outcomes:**
  1. insert the redemption `ON CONFLICT DO NOTHING`. On conflict (this account already
     redeemed this code) → **replay**: return the account's existing entitlements with 200.
     Never re-grant a revoked entitlement, and do not touch the counter;
  2. guarded `UPDATE promo_codes SET activations = activations + 1 WHERE … activations <
     max_activations AND not expired AND not disabled RETURNING`. **No row** → roll back the
     redemption insert, answer 400 `invalid_promo_code`, and count one failure;
  3. insert the entitlement.

  The last activation cannot be taken twice under concurrency.
- **Errors:**
  - unknown, expired, exhausted, disabled and bad-alphabet codes are one identical 400
    `invalid_promo_code`, and each counts as a failure for the lockout and the breaker;
  - a malformed body → 422 `validation_error`; rate limit → 429 `rate_limited`.
- The failure slot of the daily lockout is **reserved atomically before the lookup** (`INCR` + `EXPIRE NX`
  in one MULTI; over the maximum it is given back and the answer is 429), so concurrent wrong guesses
  cannot exceed `PROMO_MAX_FAILED_PER_DAY`. It is released on every outcome except a rejected code.
- Accepted: a code with characters outside the alphabet is rejected without a database lookup, so
  it answers marginally faster than an unknown or unusable code. The alphabet is public, so this
  tells an attacker nothing about stored codes.
- `promo_code` joins `SENSITIVE_KEYS` and `SENTRY_SECRET_KEYS`.

### 5. Admin CLI and audit

- No HTTP admin surface in this slice. `python -m app.admin` runs inside the regional
  deployment with its database. It is run through `docker compose exec` or `run --rm` on the
  regional host, **never from CI**:
  - `entitlement grant --kind … [--expires …] --actor …` reads the e-mail from **stdin**, so it
    never lands in argv, shell history or process lists. `entitlement revoke --account-id …
    --kind … --actor …`;
  - an unknown account, or a pending-deletion one for a grant, → exit 2 (no HTTP, so no enumeration
    surface); a revoke is allowed for a pending-deletion account (harmless);
  - replaying a grant is a no-op;
  - `promo create --label --kind --max-activations [--expires] [--grant-days] [--count]
    --actor` prints the codes once. `--count` is capped at 100 per run. `promo list` shows
    metadata and never digests. `promo disable <id>`.
- `--actor` is **self-declared**. The CLI also records the OS user and the host in the audit
  row, so a self-declared handle is never the only trace.
- Table `admin_audit (id, at, actor text 1..64 CHECK no '@', action CHECK IN (…),
  target_user_id null fk ON DELETE SET NULL, object_id null, kind null, os_user text null,
  host text null)`:
  - the actor is an operator handle, never an e-mail; `os_user` and `host` are operator data,
    never e-mails or account data;
  - `object_id` is a promo code, entitlement or purchase id, **never a user id**;
  - targets are account ids only (`target_user_id`);
  - rows about a user are exported; the operator columns (`actor`, `os_user`, `host`) are
    excluded from export (ADR 0016 §7). On erasure the row stays, without the person: the
    `target_user_id` is nulled (`SET NULL`), and `object_id` is nulled on rows whose
    `target_user_id` was the erased user.
- **Retention:** `ADMIN_AUDIT_RETENTION_DAYS=365` (default). The daily retention job deletes
  older rows.

### 6. Payments backend (5.10)

- Table `purchases (id, user_id fk CASCADE, store CHECK IN (app_store, rustore, google_play),
  product_id, original_transaction_id, environment CHECK IN (production, sandbox),
  purchased_at, verified_at, revoked_at null, UNIQUE (store, original_transaction_id))`:
  - `original_transaction_id` is a generic column: each store's verifier maps its stable
    purchase identifier into it (StoreKit's `originalTransactionId` for `app_store`);
  - the raw JWS or purchase token is never stored;
  - personal, exported, erased.
- A verifier protocol in `payments/base.py` with a registry per store.
- **Stores per region** (the registry): RU `rustore`, `app_store`; EU `app_store`,
  `google_play`. Any other store/region pair is refused at startup. RuStore Pay is therefore
  refused in EU.
- **App account token.** `app_account_token` is a server-derived per-account UUID:
  HMAC-SHA256 of the `user_id` with a dedicated `PAYMENTS_APP_ACCOUNT_KEY` (32 random bytes,
  base64; per region; distinct from every other key; not rotated while purchases exist). It is
  returned by `GET /v1/me/entitlements` as `app_account_token`, and the client passes it to the
  store at purchase.
- **StoreKit 2:**
  - the JWS `x5c` chain is validated to the pinned Apple Root CA G3 (`AppleRootCA-G3.cer`
    shipped with the code), with the Apple marker OIDs on leaf and intermediate, signature
    ES256;
  - `bundleId` = `PAYMENTS_APPLE_BUNDLE_ID`; the product is in the `PAYMENTS_PRODUCTS`
    allowlist;
  - `type` must be `Non-Consumable`;
  - `inAppOwnershipType=FAMILY_SHARED` is refused;
  - `environment` must be `Production` or `Sandbox`; `Xcode` is invalid. Sandbox is accepted
    only with `PAYMENTS_ALLOW_SANDBOX`, which is refused in prod;
  - `appAccountToken` must be present and equal the server-derived token of the caller. Missing
    or different → `invalid_purchase`;
  - a transaction with a `revocationDate` is refused;
  - the `original_transaction_id` deduplicates: a row held by another account → 409
    `purchase_already_claimed`.

  Verification is offline: the backend sends nothing to Apple. **No OCSP check**, so a revoked
  Apple intermediate is not detected (accepted and recorded, §Consequences). A root override
  (`PAYMENTS_APPLE_ROOT_CERT_PATH`) exists only outside strict environments, for the generated
  test chain.
- `POST /v1/me/purchases` has a rate limit and a body size limit (`PAYMENTS_MAX_BODY_BYTES`,
  default 16 KiB; a StoreKit JWS is a few KB).
- **RuStore Pay and Google Play** are stubs → 503 `store_unavailable`.
- `POST /v1/me/purchases` behind `FEATURE_PAYMENTS=false` (403):
  - a verified purchase → 201 with the entitlements (both kinds, Q2); replay by the same
    account → 200;
  - the same transaction claimed by another account → 409 `purchase_already_claimed`;
  - invalid → 400 `invalid_purchase`.
- Signed transactions and purchase tokens join `SENSITIVE_KEYS` and `SENTRY_SECRET_KEYS`.
- Refunds and revocation through App Store Server Notifications are not in this slice
  (`revoked_at` is ready for them).

### 7. Soft limits tied to payments

`FEATURE_SOFT_LIMITS=true` requires `FEATURE_PAYMENTS=true` in strict environments (TZ §1:
limits only together with payment). The relatives limit in `invites.py` is skipped for the
account with an effective `limits_lifted`. The PDF-report limit of TZ §1 is not wired in this
slice.

### 8. Privacy and regions

- Entitlements, redemptions and purchases hold no medical data, and medical context never
  enters them, nor ad decisions or analytics. Ads appear only on the allowlisted screens of
  §2 (`settings`, `about`); never on reminder, dose, medication, relatives, report, catalog,
  scan, consent or export screens (privacy rule 8; the remote-config validator of 5.12
  enforces the same list).
- Codes, keys, purchases and audit rows are per region. Nothing is shared across
  deployments.
- Third parties: the backend sends nothing to any store in this slice (StoreKit verification is
  offline, other stores are stubs). The client passes `app_account_token` to Apple at purchase
  time; it is a keyed, server-derived pseudonym of the account. The stores become processors of
  payment data when store accounts exist; they are listed then, per region (RuStore RU only).

## Consequences

Positive:
- An ads-free state works today through promo codes and grants, independent of store
  billing.
- One effective-state rule serves purchase, promo and grant.
- Brute force on codes is bounded per account, per IP and globally, and fails closed for
  callers who already failed today.
- Operators leave an audit trail without e-mails, with a second trace the operator cannot
  self-declare away.

Negative:
- Redis is on the redeem path: an outage disables redemption (by design).
- CLI-only administration needs shell access to the regional deployment.
- A purchase deduplicated by original transaction id cannot move between accounts without an
  operator.
- Offline StoreKit verification does not detect a revoked Apple intermediate (no OCSP). Accepted
  and recorded.
- Global breaker is alert-only: a distributed guesser below the per-caller limits is not
  stopped by it, only seen in the alert.

Follow-ups:
- 5.3, 5.4, 5.10, A2.
- Store SDKs and server notifications once accounts exist.
- The PDF-report soft limit.
- Promo and ad-removal terms (legal).

## Alternatives considered

- **Entitlement as a flag on `users`.** No source, expiry or revocation history; rejected.
- **Plain sha256 of the code.** A database dump allows offline guessing of short codes; the
  HMAC with a per-region key prevents that. Rejected.
- **Storing the code encrypted for re-display.** Codes are shown once by design; rejected.
- **HTTP admin endpoints.** A new privileged public surface; rejected for the CLI.
- **Fail open when Redis is down.** Turns an outage into an unbounded guessing window;
  rejected.
- **Blocking every caller while the global breaker is open.** Turns one guesser into an outage
  for all users; rejected in favour of alert-only plus per-caller blocking.
- **Calling Apple's App Store Server API to verify.** Needs store credentials that do not
  exist; the offline JWS chain check is enough for this slice.
- **Entitlements inherited by relatives or co-guardians.** Contradicts the owner decision of
  2026-10-22; rejected.
