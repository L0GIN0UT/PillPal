# ADR 0010 — Account deletion: grace period and restore (Phase 3)

- Status: accepted
- Date: 2026-10-16
- Scope: TZ §2.6 ("Удаление аккаунта … требование сторов и законов"), §3; backend
  `DELETE /v1/me`, `POST /v1/auth/login`, new `POST /v1/auth/restore`, `users`,
  `app/services/erasure.py`, ARQ job `erase_expired_accounts`; app delete dialog and
  restore screen
- Related: owner decisions D1 and D2 (`docs/phase3-plan.md`), ADR 0005 §5 (managed
  archive), ADR 0006 (scope visibility), ADR 0007 (detector), ADR 0008 (push tokens),
  `.claude/rules/privacy.md` rule 7
- Supersedes: the Phase 1 behaviour "`DELETE /me` erases the account and all its data in
  one transaction; the address can register again" (`backend/README.md`, data model
  section). The code and README change in milestone 3.2b.

## Context

Phase 1 erases an account immediately and irreversibly on `DELETE /v1/me` (password
confirmed). With relatives that becomes harsh: a mistaken or impulsive deletion would cut
off every relative at once, destroy managed profiles that others care for, and lose years
of history with no way back. The owner decided (D2) that deletion is first an archive the
user can restore, and only then a hard erase.

The window must stay within what law and stores allow:

- **152-FZ art. 21 part 5:** when the data subject withdraws consent, the operator must stop
  processing and, if retention is no longer needed for the purposes of processing, destroy
  the data within **thirty days** of receiving the withdrawal (unless a contract, another
  agreement or a law provides otherwise). Source read: text of art. 21 at
  `https://rulaws.ru/amp/laws/Federalnyy-zakon-ot-27.07.2006-N-152-FZ/Statya-21/`.
- **GDPR art. 17(1)** requires erasure "without undue delay"; **art. 12(3)** requires acting
  on a request without undue delay and in any event within one month (extendable only in
  justified cases, with notice).
- **App Store Review Guideline 5.1.1(v):** "If your app supports account creation, you must
  also offer account deletion within the app"
  (`https://developer.apple.com/app-store/review/guidelines/`). Apple's guidance adds that
  "only offering to temporarily deactivate or disable an account is insufficient", that
  users must be told if deletion takes additional time, and that the time taken must
  comply with local laws (`https://developer.apple.com/support/offering-account-deletion-in-your-app/`).
- **Google Play account deletion policy:** apps must provide an in-app path and a web
  resource to delete the account "and associated data"; data may be retained for
  legitimate reasons (security, fraud prevention, regulatory compliance) when users are
  clearly informed (`https://support.google.com/googleplay/android-developer/answer/13327111`).

## Decision

### 1. Two stages: request, then erase

`DELETE /v1/me` (password-confirmed, 204, unchanged contract) **does not erase**. In one
transaction under the user's journal lock it:

1. sets `users.deletion_requested_at = now` and
   `users.erase_after = now + ACCOUNT_DELETION_GRACE_DAYS − ACCOUNT_ERASURE_JOB_INTERVAL`
   (§4); the account is now `pending_deletion`;
2. revokes every refresh-token family and deletes all the user's push tokens (with their
   pending outbox rows);
3. revokes the user's open invites;
4. turns each owned managed profile into a D1 archive with
   `archive_reason = 'owner_pending_deletion'` (ADR 0005 §5): co-guardians keep read-only
   access, everyone else loses it;
5. leaves all data in place.

While `pending_deletion`:

- access JWTs of the user are refused by `get_current_user`; refresh fails (families
  revoked); the user cannot act;
- the user's profiles are invisible to relatives: their grants are kept but inactive, so
  relatives' devices see the scopes in `revoked` and evict them (ADR 0006 §5); managed
  profiles stay visible only to co-guardians as archives;
- the user's own grants on other people's profiles are inactive too;
- the missed-dose detector skips the user's profiles and never alerts the user (ADR 0007);
- processing for relatives, detection and push has therefore stopped at the request,
  which is what 152-FZ art. 21(5) requires first; only storage remains.

### 2. Restore

- `POST /v1/auth/login` with the right e-mail and password, while `erase_after > now`,
  returns `403` with code `account_pending_deletion` and
  `details: {restore_ticket, erase_after}`. As with `email_not_verified`, this answer comes
  only after a correct password, so it reveals nothing to a guesser; a wrong password gets
  the usual `401 invalid_credentials`. The error envelope gains an optional `details`
  object holding server-generated values only.
- The restore ticket is 256 bits, stored as `sha256` in Redis with TTL
  `ACCOUNT_RESTORE_TICKET_TTL_SECONDS` (600), single use (`GETDEL`).
- The app shows "Restore account" with the erase date; on explicit confirmation it calls
  `POST /v1/auth/restore {restore_ticket}` (rate-limited per IP, optional `X-Device-ID`).
  The server locks the user row, re-checks `erase_after > now`, clears both columns,
  un-archives the profiles archived with `owner_pending_deletion`, touches the device and
  returns a new token pair. Grants become active again; relatives' devices see the scopes
  return and backfill from cursor 0. No data has to be re-entered.
- An unknown, used or expired ticket, or an account past `erase_after`, gives
  `401 invalid_token`.
- Push tokens and invites are not restored: the app registers its token again after
  sign-in, and invites are one-time anyway.

### 3. Registration and password reset during the grace period

- `POST /v1/auth/register` with the e-mail of a pending account returns the same `202` and
  body as for any address (no enumeration). The mail sent to the existing address says the
  account is scheduled for deletion and how to restore it. The unique e-mail index keeps a
  second account from being created.
- Password reset works as today (so a user who forgot the password can still restore); it
  does not restore by itself, and the next login offers the restore.
- After `erase_after` the account behaves as unknown to login; after the hard erase the
  address can register again.

### 4. Grace period: 30 days, and why not longer

- `ACCOUNT_DELETION_GRACE_DAYS = 30`, configurable, validated to `1..30`.
- The **hard erase completes within the grace period counted from the request**: the job
  runs every `ACCOUNT_ERASURE_JOB_INTERVAL_SECONDS` (3600) and `erase_after` is set one
  interval early, so erasure happens no later than `request + grace`. With the default this
  meets the 30-day limit of 152-FZ art. 21(5) and the one-month limit of GDPR art. 12(3).
  The job is hourly rather than daily for this reason: a daily job would let erasure slip
  up to a day past the limit.
- The restore window shown to the user is `erase_after`, which the user is told in the
  deletion dialog and on the restore screen (Apple: inform users when deletion takes
  additional time).
- **An indefinite (or longer than 30-day) archive would not be compliant**: it is the
  "temporary deactivation" Apple rejects, it is not deletion of associated data in Google
  Play's sense, and it exceeds the 152-FZ and GDPR deadlines. The grace period can only be
  lengthened after legal review, which would also have to establish a legal basis other
  than consent for keeping the data.
- Backups are outside this ADR (no deployment exists); Phase 5 must keep backup retention
  consistent with these deadlines.

### 5. Hard erase

ARQ cron `erase_expired_accounts` (hourly) selects `users WHERE erase_after <= now ORDER BY
erase_after LIMIT n FOR UPDATE SKIP LOCKED`, re-checks the condition, and runs
`erase_account` per user in its own transaction. `erase_account` first applies the **D1
transfer**: each managed profile with at least one co-guardian moves to the earliest
co-guardian (whose guardian grant is deleted), its viewer/editor grants are deleted, and
`archive_reason` becomes `owner_erased`; the journal locks of both owners are taken in
sorted order. Then it erases everything else the user owns, including the Phase 3 tables
(grants, invites, push tokens, outbox, alerts, journal of still-owned scopes), as listed in
`docs/phase3-plan.md`. A restore racing the job is serialized on the user row: exactly one
wins.

The job logs `account_erased` with the user id only. The function lands in 3.2b and the
cron registration in 3.4, when the worker exists.

### 6. Unchanged

- The data export (Phase 5) is unaffected: it reads the same table inventory and is
  available to an active account.
- The device that requested deletion wipes its local data at once (ADR 0002 §1); a restore
  re-pulls from the server.

## Consequences

- `users` gains `deletion_requested_at` and `erase_after` (both or neither; partial index
  for the job); `profiles` gains `archived_at` and `archive_reason` (ADR 0005 §5).
- The needle test for erasure now drives the full path: request, the grace period on a fake
  clock, then the job.
- Phase 1 tests that assert immediate erasure on `DELETE /v1/me` and re-registration right
  after are rewritten in 3.2b; `backend/README.md` is updated there by `doc-updater`.
- The app gains a restore screen and a deletion dialog that states the date and what
  happens to each managed profile.
- During the grace period the account still occupies its e-mail address.

## Alternatives considered

- **Keep immediate erasure** (Phase 1): simplest and compliant, but rejected by the owner
  (D2) for the reasons in the context.
- **Soft-delete flag without an erase job:** an indefinite archive; not compliant (§4).
- **Restore by e-mail link instead of login:** works without the password, but needs a
  mailed capability for a destructive-path reversal; login with the password plus explicit
  confirmation is simpler and proves the same person.
- **Grace period longer than 30 days** (60 or 90, as some services use): exceeds the
  152-FZ deadline for consent-based processing; would need legal review (§4).
- **Erase managed profiles with the owner even when co-guardians exist:** loses the history
  co-guardians rely on; D1 keeps it as an archive.
