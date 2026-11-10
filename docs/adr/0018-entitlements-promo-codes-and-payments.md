# ADR 0018 — Entitlements, promo codes and payments (Phase 5)

- Status: Accepted (owner decisions 2026-11-10)
- Date: 2026-11-10
- Scope: TZ §1 ("Монетизация", "Реклама", "Публикация"), §5 "Фаза 5", §6 ("Оплата"); backend
  migrations `0018_entitlements`, `0019_admin_audit`, `0020_promo_codes`, `0023_purchases`;
  `app/settings_entitlements.py`, `app/settings_payments.py`, `app/domain/entitlements.py`,
  `app/admin/`, `app/payments/{base,storekit,rustore,play,registry}.py`, services
  `entitlements`, `promo`, `purchases`; routers `me_entitlements`, `purchases`; `invites.py`
  (soft limits); `observability.py`; app A2
- Related: owner decisions of 2026-10-22 (Phase 4 appendix: `ads_removed` per account, promo
  codes) and Q2 (`docs/phase5-plan.md`), ADR 0005 (relatives and managed profiles), ADR 0016
  §9 (key separation), `.claude/rules/security.md`, `.claude/rules/privacy.md` rules 1, 2, 8

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
  `Cache-Control: private, no-store`. It works with `FEATURE_PAYMENTS=false`.
- **App (A2):**
  - caches the result per account, refreshed on sign-in and daily;
  - on failure keeps the last value for 14 days; clears it on sign-out;
  - `adsAllowedProvider(screen)` is pure: always false on reminder and dose screens, false
    with `ads_removed`;
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
- **Normalisation.** Uppercase, spaces and hyphens removed. Anything outside the alphabet is
  an invalid code.
- **Storage.** `HMAC-SHA256(PROMO_CODE_HMAC_KEY, normalized)`, compared with
  `hmac.compare_digest`. The plaintext is never stored, listed or logged.
  `PROMO_CODE_HMAC_KEY` rules:
  - at least 32 characters, per region;
  - must differ from `JWT_SECRET` and `DATA_ENCRYPTION_KEY`;
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
4. global breaker: 200 failures per 3600 s opens it for 900 s → 503 `promo_unavailable`;
5. lookup by digest.

- **Fail closed:** if Redis (limits, lockout, breaker) is unavailable, the answer is 503
  `promo_unavailable`, never an unchecked lookup.
- **One transaction:**
  1. insert the redemption ON CONFLICT DO NOTHING;
  2. guarded `UPDATE promo_codes SET activations = activations + 1 WHERE … activations <
     max_activations AND not expired AND not disabled RETURNING`;
  3. insert the entitlement.

  The last activation cannot be taken twice under concurrency. The same account redeeming
  again → 200 with its entitlements.
- **Errors:**
  - unknown, expired, exhausted, disabled and bad-alphabet codes are one identical 400
    `invalid_promo_code`, and each counts as a failure for the lockout and the breaker;
  - a malformed body → 422 `validation_error`; rate limit → 429 `rate_limited`.
- `promo_code` joins `SENSITIVE_KEYS` and `SENTRY_SECRET_KEYS`.

### 5. Admin CLI and audit

- No HTTP admin surface in this slice. `python -m app.admin` runs inside the regional
  deployment with its database:
  - `entitlement grant --kind … [--expires …] --actor …` reads the e-mail from **stdin**, so it
    never lands in argv, shell history or process lists. `entitlement revoke --account-id …
    --kind … --actor …`;
  - an unknown or pending-deletion account → exit 2 (no HTTP, so no enumeration surface);
  - replaying a grant is a no-op;
  - `promo create --label --kind --max-activations [--expires] [--grant-days] [--count]
    --actor` prints the codes once. `promo list` shows metadata and never digests.
    `promo disable <id>`.
- Table `admin_audit (id, at, actor text 1..64 CHECK no '@', action CHECK IN (…),
  target_user_id null fk ON DELETE SET NULL, object_id null, kind null)`:
  - the actor is an operator handle, never an e-mail; targets are account ids only;
  - rows about a user are exported. On erasure the row stays, without the person
    (`SET NULL`).

### 6. Payments backend (5.10)

- Table `purchases (id, user_id fk CASCADE, store CHECK IN (app_store, rustore, google_play),
  product_id, store_transaction_id, environment CHECK IN (production, sandbox), purchased_at,
  verified_at, revoked_at null, UNIQUE (store, store_transaction_id))`:
  - the raw JWS or purchase token is never stored;
  - personal, exported, erased.
- A verifier protocol in `payments/base.py` with a registry per store.
- **StoreKit 2:**
  - the JWS `x5c` chain is validated to the pinned Apple Root CA G3 (`AppleRootCA-G3.cer`
    shipped with the code), with the Apple marker OIDs on leaf and intermediate, signature
    ES256;
  - `bundleId` = `PAYMENTS_APPLE_BUNDLE_ID`; the product is in the `PAYMENTS_PRODUCTS`
    allowlist;
  - `environment` is accepted only if allowed: sandbox needs `PAYMENTS_ALLOW_SANDBOX`, which
    is refused in prod;
  - a transaction with a `revocationDate` is refused;
  - the original transaction id deduplicates.

  Verification is offline: the backend sends nothing to Apple. A root override
  (`PAYMENTS_APPLE_ROOT_CERT_PATH`) exists only outside strict environments, for the
  generated test chain.
- **RuStore Pay and Google Play** are stubs → 503 `store_unavailable`. RuStore Pay is refused
  in EU.
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
  enters them, nor ad decisions or analytics. Ads never appear on reminder, dose, medication
  or catalog screens (privacy rule 8; the remote-config validator of 5.12 enforces the same
  list).
- Codes, keys, purchases and audit rows are per region. Nothing is shared across
  deployments.
- Third parties: none receive data from the backend in this slice (StoreKit verification is
  offline, other stores are stubs). The stores become processors of payment data when store
  accounts exist; they are listed then, per region (RuStore RU only).

## Consequences

Positive:
- An ads-free state works today through promo codes and grants, independent of store
  billing.
- One effective-state rule serves purchase, promo and grant.
- Brute force on codes is bounded per account, per IP and globally, and fails closed.
- Operators leave an audit trail without e-mails.

Negative:
- Redis is on the redeem path: an outage disables redemption (by design).
- CLI-only administration needs shell access to the regional deployment.
- A purchase deduplicated by original transaction id cannot move between accounts without an
  operator.

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
- **Calling Apple's App Store Server API to verify.** Needs store credentials that do not
  exist; the offline JWS chain check is enough for this slice.
- **Entitlements inherited by relatives or co-guardians.** Contradicts the owner decision of
  2026-10-22; rejected.
