# ADR 0010 — Account deletion: grace period and restore (Phase 3)

- Status: accepted
- Date: 2026-10-16 (revised after the PR #12 reviews)
- Scope: TZ §2.6 ("Удаление аккаунта … требование сторов и законов"), §3; backend
  `DELETE /v1/me`, `POST /v1/auth/login`, `POST /v1/auth/refresh`, new
  `POST /v1/auth/restore`, `users`, `email_codes`, `app/services/erasure.py`, ARQ job
  `erase_expired_accounts`; app deletion dialog and restore screen
- Related: owner decisions D1 and D2 (`docs/phase3-plan.md`, milestone 3.3b), ADR 0005 §5
  (managed archive), ADR 0006 (scope visibility), ADR 0007 (detector), ADR 0008 (push
  tokens and send-time checks), `.claude/rules/privacy.md` rule 7
- Supersedes: the Phase 1 behaviour "`DELETE /me` erases the account and all its data in
  one transaction; the address can register again" (`backend/README.md`). Code and README
  change in milestone 3.3b.

## Context

Phase 1 erases an account immediately and irreversibly on `DELETE /v1/me` (password
confirmed). With relatives that is harsh: a mistaken or malicious deletion cuts off every
relative at once, destroys managed profiles that others care for, and loses years of
history. The owner decided (D2) that deletion is first an archive the user can restore,
and only then a hard erase.

The window must stay within what law and stores allow:

- **152-FZ art. 21 part 5:** after the data subject withdraws consent, the operator must stop
  processing and, if retention is no longer needed for the purposes of processing, destroy
  the data within **thirty days** of receiving the withdrawal (unless a contract, another
  agreement or a law provides otherwise). Text read at
  `https://rulaws.ru/amp/laws/Federalnyy-zakon-ot-27.07.2006-N-152-FZ/Statya-21/`.
- **GDPR art. 17(1)**: erasure "without undue delay"; **art. 12(3)**: act on a request without
  undue delay and in any event within one month (extendable only in justified cases).
- **App Store Review Guideline 5.1.1(v):** "If your app supports account creation, you must
  also offer account deletion within the app"
  (`https://developer.apple.com/app-store/review/guidelines/`). Apple adds that "only
  offering to temporarily deactivate or disable an account is insufficient", that users
  must be told if deletion takes additional time, and that the time taken must comply with
  local laws (`https://developer.apple.com/support/offering-account-deletion-in-your-app/`).
- **Google Play account deletion policy:** an in-app path and a web resource to delete the
  account "and associated data"; data may be retained for legitimate reasons when users are
  clearly informed (`https://support.google.com/googleplay/android-developer/answer/13327111`).

Whether 30 days of blocked storage for restore is acceptable after a withdrawal, and
whether an "erase immediately" option must also be offered, are open legal questions
(`docs/phase3-plan.md`, "Legal review required before launch"). This ADR does not add that
option: D2 is archive-with-restore.

## Decision

### 1. Request

`DELETE /v1/me` (password-confirmed, 204, unchanged contract) **does not erase**. In one
transaction it takes `SELECT … FOR UPDATE` on the user row (serializing with login,
refresh and restore), then the user's journal lock, and:

1. sets `deletion_requested_at = now`,
   `erase_after = now + ACCOUNT_DELETION_GRACE_DAYS − 2 × ACCOUNT_ERASURE_JOB_INTERVAL` (§4), and
   `tokens_not_before = now` (access JWTs issued earlier are refused);
2. revokes every refresh-token family; deletes all the user's push tokens and marks pending
   outbox rows about the user's profiles `dropped` (implemented in 3.4, in the request's own
   transaction);
3. revokes the user's open invites;
4. archives each owned managed profile **that is not already archived** with
   `archive_reason = 'owner_pending_deletion'` (ADR 0005 §5): co-guardians keep read-only
   access and may only leave;
5. sends the mail "deletion requested; the account will be erased on {erase_after}; if this
   wasn't you, restore it and change your password";
6. leaves all data in place.

While `pending_deletion`:

- no token is issued or rotated: the check is **centralized** in `_issue_tokens` and
  `refresh`, so login, verify-email, password reset and refresh cannot hand out a working
  session; `get_current_user` refuses older access JWTs via `tokens_not_before`;
- the user's profiles are invisible to relatives (grants inactive; relatives' devices evict
  the scopes, ADR 0006 §5); owners see inactive grants as `active: false` and may revoke them;
- the user's own grants on other profiles are inactive;
- the detector skips the user's profiles and never alerts the user (ADR 0007), and pushes
  about them are dropped at send time (ADR 0008 §6);
- processing for relatives, detection and push has stopped at the request, which is what
  152-FZ art. 21(5) requires first; only blocked storage remains.

### 2. Restore: password, ticket and e-mail code

- `POST /v1/auth/login` with the right password while `erase_after > now` returns `403`
  `account_pending_deletion` with `details: {restore_ticket, erase_after}` and mails a
  one-time code with the new purpose `restore_account` (existing budget mechanics:
  `_new_code_capped`, `_consume_code`, attempt limits). As with `email_not_verified`, this
  answer comes only after a correct password; a wrong one gets `401 invalid_credentials`.
- The ticket is 256 bits, stored as `sha256` in Redis, TTL 600 s, single use. It is a bearer
  secret in an error body: Sentry `before_send` scrubs `restore_ticket`, and the app never
  logs error bodies. The error envelope gains an optional `details` object (server-generated
  values only).
- The ticket is bound to the deletion cycle (`users.deletion_requested_at`): after a restore
  and a new request, a ticket of the earlier cycle is refused (`invalid_token`), checked under
  the row lock before the code is consumed.
- `POST /v1/auth/restore {restore_ticket, code}` (rate-limited): locks the user row,
  re-checks `erase_after > now`, consumes the code, then clears the deletion columns, sets
  `tokens_not_before = now`, un-archives the profiles archived with `owner_pending_deletion`
  that are not deleted, touches the device, returns a new token pair, mails "account
  restored", and (since 3.4) sends `link_restored` (ids only) to the owners of profiles the
  account holds grants on. Grants become active; relatives' devices backfill from cursor 0.
  Nothing has to be re-entered.
- A missing or wrong code, an unknown, used or expired ticket, or an account past
  `erase_after` → `401 invalid_token`.

A leaked password alone therefore can neither restore an account nor reactivate its access
to other people's profiles; it can still request a deletion, which the mail reports and the
real user can undo.

**Refresh after a crash.** A client that crashes between a refresh rotation and persisting
the new pair would present the old token again and revoke its family. Refresh is therefore
idempotent for `REFRESH_REUSE_WINDOW_SECONDS` (30): the same old token from the same device
within the window returns the same new pair (cached in Redis under `sha256(old token)`,
encrypted with a key derived from the old token); outside the window or from another
device, reuse still revokes the family (milestone 3.7, ADR 0001 addendum). Pending
accounts never get a pair.

### 3. Registration and password reset during the grace period

- `POST /v1/auth/register` with the address of a pending account returns the same `202` and
  body as for any address (no enumeration). The mail to the existing address explains the
  pending deletion and how to restore by signing in; it contains no ticket and no link
  capability. The unique e-mail index prevents a second account.
- Password reset works as today and does not restore by itself; the next login offers the
  restore.
- After `erase_after` the account is unknown to login; after the hard erase the address can
  register again.

### 4. Grace period: 30 days, and why not longer

- `ACCOUNT_DELETION_GRACE_DAYS = 30`, configurable, validated to `1..30`.
- The hard erase completes within the grace period counted from the request: the job runs
  every `ACCOUNT_ERASURE_JOB_INTERVAL_SECONDS` (3600) and `erase_after` is set two intervals
  early, so erasure happens no later than `request + grace` — within the 30-day limit of
  152-FZ art. 21(5) and the one-month limit of GDPR art. 12(3). A daily job could let
  erasure slip almost a day past the limit.
- The dialog and the restore screen show `erase_after`. The dialog also says that relatives
  lose access at once, that data is kept blocked only to allow restore, what happens to each
  managed profile (archive for co-guardians kept `MANAGED_ARCHIVE_RETENTION_DAYS`, or
  erased), and that notes in managed profiles stay with co-guardians.
- **An indefinite (or longer than 30-day) archive would not be compliant**: it is the
  "temporary deactivation" Apple rejects, it is not deletion of associated data in Google
  Play's sense, and it exceeds the 152-FZ and GDPR deadlines. The grace period can only be
  lengthened after legal review, which would also need a legal basis other than consent.
- Backups are outside this ADR (no deployment exists); Phase 5 keeps backup retention
  consistent with these deadlines.

### 5. Hard erase

ARQ cron `erase_expired_accounts`, hourly (since 3.4: `app.worker`, minute :05; the worker
refuses to start when `ACCOUNT_ERASURE_JOB_INTERVAL_SECONDS` is not the cron's 3600, because
the `erase_after` margin below assumes it; `python -m app.jobs.account_erasure` remains for
one-off runs). **A deployment needs the worker (or an equivalent cron): nothing else completes
a deletion.** It **loops until no due user remains**: each
user in its own transaction that takes `SELECT … FOR UPDATE SKIP LOCKED` on the user row
(the lock is held for that user's work, not lost between a select and later transactions),
re-checks `erase_after <= now`, and runs `erase_account`. A gauge `erasure_overdue_count`
(users due for longer than one interval) alerts operations. A restore racing the job is
serialized on the user row: exactly one wins.

`erase_account` first applies the **D1 transfer** (ADR 0005 §5): each archived managed
profile with an **active** co-guardian moves to the earliest one (their grant deleted),
viewer/editor grants are deleted, `archive_reason = owner_erased`,
`archive_purge_after = now + MANAGED_ARCHIVE_RETENTION_DAYS`, and `updated_by_device` is
cleared; the journal locks of both owners are taken in sorted order. Then it erases
everything else the user owns, including grants, invites (others' `consumed_by_user_id`
nulled), push tokens, outbox rows, alerts and the journal of still-owned scopes, as listed
in `docs/phase3-plan.md`. The job logs `account_erased` with the user id only.

### 6. Unchanged

- The data export (Phase 5) is unaffected: it reads the same table inventory and is
  available to an active account.
- The device that requested deletion wipes its local data at once (ADR 0002 §1); a restore
  re-pulls from the server.

## Consequences

- `users` gains `deletion_requested_at`, `erase_after` and `tokens_not_before`;
  `email_codes.purpose` gains `restore_account`; `profiles` gains the archive columns
  (ADR 0005 §5). Migrations `0008_user_deletion_grace`, `0009_profile_archive`.
- The needle test drives the full path: request, the grace period on a fake clock, the job.
- Phase 1 tests asserting immediate erasure and immediate re-registration are rewritten in
  3.3b; `backend/README.md` is updated there.
- The app gains a restore screen (ticket from the login error, code from the mail) and a
  deletion dialog with the disclosures above.
- During the grace period the account still occupies its e-mail address.

## Alternatives considered

- **Keep immediate erasure** (Phase 1): compliant and simple, rejected by the owner (D2).
- **Restore with the password only:** a leaked password would revive the account and its
  access to relatives' data; the e-mail code closes that.
- **Restore by an e-mail link only:** a mailed capability for reversing a destructive
  action, without proof of the password; password + ticket + code is stronger.
- **Soft-delete flag without an erase job:** an indefinite archive; not compliant (§4).
- **Grace period longer than 30 days:** exceeds the 152-FZ deadline for consent-based
  processing; needs legal review.
- **Erase managed profiles with the owner even when co-guardians exist:** loses the history
  the co-guardians rely on; D1 keeps it as an archive.
