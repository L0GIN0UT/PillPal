# ADR 0020 — 15-minute invite codes, invite status, masked inviter e-mail, private relative notes

- Status: Accepted (owner decisions 2026-11-14, relatives redesign PR2, backend)
- Date: 2026-11-14
- Scope: TZ §2.5 ("Близкие"); backend `app/services/invites.py`, `invite_accept.py`,
  `relative_notes.py`, `grants.py`, `jobs/retention.py`, `services/erasure.py`,
  `services/personal_data.py`, migration `0025_relative_notes`; `docs/spec/export.md`
- Amends: ADR 0005 §3–§4 (invite TTL, grant deletion), ADR 0009 §4 (TTL, preview, status)
- Related: `.claude/rules/privacy.md` rules 1, 2, 4, 7; `.claude/rules/security.md`

## Context

The relatives redesign shows the invite as a QR code that the other person scans while both
are together, and tells the owner on screen when the scan succeeded. A 7-day (24 h for
guardians) link is far longer than that moment needs and keeps a bearer capability alive for
days. The scanner wants to check who shares before accepting, and users want to label relatives
the way they think of them ("Сын", "Мама") without that label reaching anyone else. An earlier
idea of a reverse invite (the ward shows a QR) is dropped: only the data owner issues a code.

## Decision

### 1. Invite codes live 15 minutes, for every role

- `INVITE_TTL_SECONDS` and `GUARDIAN_INVITE_TTL_SECONDS` default to 900. Still single use, still
  at most 5 open per profile, the token still 256 bits in the URL fragment (ADR 0009 §1).
- `InviteCreated` gains `created_at` (server time) next to `expires_at`, so the app counts down
  from the server's own pair and a skewed phone clock does not shorten or stretch the code.
- When the code runs out, the app creates a new one (and revokes the old one if still open).
  Invite creation gets its own budget, `INVITE_CREATE_RATE_LIMIT_ATTEMPTS` = 30 per account and
  15-minute window (the per-IP bucket is 10 times wider, as for every limited scope). The screen
  needs one code per 15 minutes by itself plus one per role switch or reopen; 30 leaves headroom
  for an indecisive user and still bounds token minting. The auth default (10) could lock a user
  out of the screen after a few role switches.

### 2. Invite status for its creator

`GET /v1/invites/{id}` → `{id, role, state, created_at, expires_at}`, `state` ∈
`open | consumed | expired | revoked`. Only the account that created the invite gets an answer;
anyone else (the accepter included) and an unknown id get the same 404, so ids cannot be probed.
An invite whose profile was deleted or archived reports `revoked` (accepting it would answer
`invite_invalid`). No token, no URL, nothing about who accepted: the creator learns that from
`GET /v1/grants`, which already lists the new relative.

The app polls it about every 3 seconds while the code is on screen (~300 reads per code). It is
**not rate limited**, like `GET /v1/grants`: an authenticated read by primary key, scoped to the
caller, that reveals only the caller's own invite.

### 3. Masked inviter e-mail in the preview

`POST /v1/invites/preview` adds `inviter_email_masked` (`app/domain/email_mask.py`):

- local part: its first character and `***` (`i***`); a local part of one or two characters is
  masked whole (`***`);
- domain: kept in full only for large public providers (`mail.ru`, `bk.ru`, `inbox.ru`,
  `list.ru`, `yandex.ru`, `ya.ru`, `gmail.com`, `icloud.com`, `outlook.com`, `hotmail.com`,
  `rambler.ru`, `proton.me`); any other domain is reduced to its first character, `***` and the
  last label (`ivan@ivanov.family` → `i***@i***.family`), because a private domain can identify
  a person by itself;
- a malformed address gives `***`.

It lets the scanner check that the code comes from the person in front of them, which a display
name alone (chosen freely) does not.

Privacy: the preview answers only a signed-in holder of a valid, open, unexpired token, which
the data owner chose to show; a used, revoked or unknown token reveals nothing (ADR 0009 §4).
The masked form discloses at most one character of the local part plus either a public
provider's domain or one character and the top-level label of any other domain; it is a hint for
someone who already knows the inviter, not the address. It is never logged (a regression test
checks the request log), never stored, and not part of any other response. The legal basis for
showing it to the token holder is an open question (`docs/legal/README.md`).

### 4. Private relative notes

A note is a label of 1–20 characters that only its author ever sees. It is trimmed, and it may
not contain control characters (C0 and C1, tabs and newlines included), bidi marks and overrides,
zero-width characters (U+200B–U+200F, ZWJ included), line and paragraph separators, U+061C or a
BOM.

- **Storage:** `relative_notes(user_id, subject_profile_id, note, created_at, updated_at)`, primary
  key `(user_id, subject_profile_id)`, both FKs `ON DELETE CASCADE`, CHECK on the length. A person
  with an account is addressed by their **self profile**, a managed profile by its own id, so one
  key covers both. `GET /v1/grants` therefore adds `grantee_profile_id` (the grantee's self
  profile) to outgoing grants: an opaque id that gives the owner no access (every profile path
  still checks the caller), only the key of the owner's own note.
- **Relationship rule:** the author may hold a note about a subject only while they are related:
  the subject is not the author's, and either the author holds an active grant on it (incoming)
  or it is the self profile of an account holding a grant on a live profile the author owns
  (outgoing). Otherwise `PUT` and `DELETE` answer 404, like a missing profile. `PUT` locks the grants that
  make the relationship `FOR SHARE` until it commits: a concurrent revoke or leave (which locks its
  grant `FOR UPDATE`) either commits first, and the `PUT` answers 404, or waits and then prunes
  the new note, so no note outlives its relationship.
- **API (REST, not sync):** `PUT /v1/relative-notes/{profile_id}` `{note}` → 200 with
  `{profile_id, note, updated_at}`; the same text again changes nothing. `DELETE` → 204, again
  204 while related. At most `MAX_RELATIVE_NOTES_PER_USER` (200) per author (409
  `too_many_notes`); writes limited to `RELATIVE_NOTE_RATE_LIMIT_ATTEMPTS` (60) per 15 minutes.
  `GET /v1/grants` returns `notes: [{profile_id, note, updated_at}]` for the subjects it lists.
  Sync scopes are per profile and notes belong to no profile's scope, so they are online-edit
  only; the app reads them from its cache offline.
- **Cleanup:** deleting a grant (revoke or leave) deletes the notes of both parties that lost
  their last relationship, in the same transaction. A daily retention sweep deletes every other
  orphan (a profile deleted, a managed profile handed over). Paused or pending grants still count
  as a relationship, so a restore keeps the notes: during an account deletion grace period
  (ADR 0010) notes stay like the grants do, and go with the hard erase. Re-linking later does not
  revive old notes. The sweep runs in its own transaction, so its failure keeps the other
  retention steps.
- **Privacy:** a note is free text of its author. Meant as a family label, it may still carry
  health context ("на диализе"), so it is handled like medical data: never logged (the log line
  carries the subject profile id only; a regression test checks the request log), never in
  errors, Sentry, analytics or push payloads, erased with the author and with the subject profile,
  and exported to the author only (`docs/spec/export.md`). Another account's note about you is
  theirs and is not in your archive (an open legal question, `docs/legal/README.md`).
  Region-local like all data.

## Consequences

- A leaked invite is usable for at most 15 minutes; guardians are no longer a special case.
- Links sent through a messenger must be used within 15 minutes; the app explains this and
  offers a fresh code.
- The app can show "X is now your relative" within seconds of the scan without push.
- Notes survive reinstalling the app (server-side) but not the end of the relationship.

## Alternatives considered

- **Keep 7 days and add a separate short QR token:** two token kinds with the same power.
- **Push only for "accepted":** push may be unavailable (RuStore, denied permission); polling a
  cheap read is simpler and works everywhere.
- **Full inviter e-mail in the preview:** discloses the address to anyone holding a forwarded
  code; the masked form is enough to recognise a person one knows.
- **Notes in sync:** they belong to no profile scope; a separate scope for a 20-character label
  is not worth the protocol change.
- **Notes keyed by user id:** a managed profile has no account; the profile id covers both.
