# ADR 0006 — Sync scopes and the privacy projection (Phase 3)

- Status: accepted
- Date: 2026-10-16
- Scope: TZ §2.1, §2.5, §4 (sync); backend `sync_changes`, `app/services/changes.py`,
  `sync.py`, `sync_pull.py`, `app/domain/privacy.py`; app sync engine and drift schema v4
- Related: ADR 0005 (roles and access matrix), ADR 0010 (pending deletion),
  `backend/README.md` (sync protocol), `docs/phase3-plan.md` (milestone 3.3, 3.6)

## Context

Phase 1 journals every change in `sync_changes(user_id, seq, entity, entity_id, op)` and
serializes writers per user with `pg_advisory_xact_lock(owner)`, so a pull cursor never
skips a row committed later with a smaller `seq`. Every loader filters by
`Profile.owner_user_id == user_id`. A relative therefore cannot receive another account's
data, and nothing in the pull knows about privacy.

Phase 3 needs pulls that mix the caller's own profiles with profiles shared with them,
each with its own role, with server-side redaction for projected roles, and with eviction
when access ends or narrows.

## Decision

### 1. The journal is keyed by profile (scope)

- `sync_changes.profile_id` replaces `user_id` (revision `0009_sync_changes_scope`;
  backfill from entity to profile, allowed in one step because no stand exists).
- `record_change(session, profile_id, entity, entity_id, op)`: every write journals into
  the scope of the affected profile, whoever makes it (owner, guardian, editor), including
  cascaded tombstones and re-journaled children after a privacy change.
- **The lock key stays the owner user id of the scope.** All scopes of one owner share one
  advisory lock, exactly as today, so the existing ordering argument still holds per owner.
  `lock_journal(session, owner_ids)` locks several owners in sorted order (deadlock-free).
  Sync push resolves the owners of every scope in a batch before applying it
  (`resolve_batch_owners`); REST writes lock the owner of the path's profile
  (`lock_for_profile`). The ownership transfer at account erasure (ADR 0005 §5) locks the
  old and the new owner.

### 2. Scoped pull

`POST /v1/sync/pull` with `{"cursors": {"<profile_id>": seq, …}, "limit": n}` (≤ 50 cursors,
limit capped at 500) returns:

- `scopes`: every accessible scope with `role`, `kind`, `archived` and its new `cursor`.
  Owned profiles are listed even when tombstoned (deletes must propagate). Granted profiles
  are listed only while the grant is active (ADR 0005 §3) and, for archived profiles, only
  to owner and guardians.
- `revoked`: requested scopes the caller cannot access. A scope that never existed, a
  foreign one, a revoked grant, an inactive grant and a deleted profile all look the same:
  no oracle.
- `changes`: one ordered page across scopes, each change tagged with `scope`.
- `has_more`.

A scope missing from `cursors` starts at 0: that is how a new grant, or a grant made active
again by an account restore, gets its backfill. A per-scope cursor is safe because it only
advances to the scope's own last returned `seq`, and each scope is serialized by its
owner's lock.

`GET /v1/sync/pull` (owner scopes, one cursor) stays until the app switches (3.6) and is
removed in 3.10.

### 3. Privacy projection (pure, `app/domain/privacy.py`)

Applied at pull time for projected roles (`editor`, `viewer`); full-access roles get the
entity unchanged.

| Entity | `shared` | `anonymous` | `hidden` |
|---|---|---|---|
| Medication | full | `{id, profile_id, privacy, tz_mode, fixed_tz, redacted: true}` | not returned |
| Schedule | full | `{id, medication_id, redacted: true, rule: {v, kind, start_date, end_date, weekdays?, interval_days?, times: [{time}]}}` (no doses) | not returned |
| Dose event | without `note`, `device_id` | without `note`, `device_id` | not returned |
| Profile | `{id, kind, display_name, timezone}` for every projected role | | |

A test classifies every field of every output schema; a new field fails the build until it
is added to the projection table.

### 4. Privacy changes and eviction

- A privacy change journals the medication with op `privacy` (journal only, never on the
  wire) and re-journals all its schedules and dose events, so relatives overwrite their
  copies with the new projection.
- A narrowing to `hidden` is emitted to projected roles as `op: delete, data: null` for the
  medication (conflict-key fields null); its children are skipped. The client hard-deletes
  the medication with its children.
- Widening re-sends the medication and all its children.

### 5. Access ends or changes

- **Grant revoked, grant inactive (ADR 0010), profile deleted:** the scope leaves `scopes`
  and appears in `revoked` if its cursor was sent. The client deletes the scope's profile,
  medications, schedules, dose events and outbox entries in one transaction. Server-side
  access ends at once. A device that never syncs again keeps its copy: remote wipe is
  impossible, and this is stated in the privacy notes.
- **Role change** (including guardian → owner at the D1 transfer): the client evicts the
  scope and re-pulls it from 0. The server does nothing special.
- **Archived scope (D1):** listed with `archived: true` to owner and guardians. The client
  stops reminders for it, renders it read-only and does not queue writes.

### 6. Writes by relatives (sync push)

| Writer | Mutation | Result |
|---|---|---|
| editor | upsert of a `shared` medication or its schedule | applied, journaled in the owner's scope |
| editor | medication upsert changing `privacy` | `rejected/forbidden_field` |
| editor | new medication not `shared` | `rejected/forbidden_field` |
| editor | anything on an `anonymous` or `hidden` medication | `rejected/not_found` |
| editor | dose event on a visible medication (D3) | `rejected/forbidden` |
| editor | dose event on a hidden or unknown medication | `rejected/not_found` |
| editor | profile upsert or delete | `rejected/read_only` |
| viewer | any | `rejected/not_found` |
| anyone | write into an archived scope (except a guardian's or owner's profile delete) | `rejected/read_only` |

LWW by `client_updated_at` (tie-break device id) is unchanged and applies between owner and
editor writes. The client parks outbox entries rejected with `not_found`, `read_only`,
`forbidden` or `forbidden_field`.

Client rules for foreign scopes: deletes are hard deletes (never local tombstones); dose
events are overwritten, not insert-if-missing (notes get stripped by the projection).

### 7. Compatibility

- `Change` gains `scope`; `ScopeOut` is new; `ProfileData` gains optional
  `missed_alert_minutes` / `missed_alerts_enabled` with keep-on-absent semantics, so
  existing full-state profile pushes do not reset them.
- drift schema v4 converts the old global `pullCursor` into a cursor for each local
  profile, all of which are owned before 3.6; valid because `seq` is global.

## Consequences

- One query per pull page (`sync_changes JOIN (VALUES (scope, cursor)…)`, index
  `(profile_id, seq)`), with the existing per-entity collapse kept per scope.
- A privacy change costs one journal row per child of the medication, bounded by its
  history; acceptable for a rare user action.
- Every relative-facing path reads through one projection module, which is ~100% covered.
- A relative's device holds only projected data, so a lost relative's phone leaks at most
  what the owner chose to share.

## Alternatives considered

- **Keep the journal per user and fan out** (one journal row per recipient): writes would
  cost O(relatives), and grants would need backfill copies.
- **Project at write time** (store redacted copies): two versions of every row and a
  rewrite on every privacy change; the projection at read time is cheaper and has one
  source of truth.
- **Lock per profile instead of per owner**: a push batch touching several profiles of one
  owner would need many locks, and the old single-cursor pull would no longer be safe
  during the transition.
- **REST access for relatives**: a second projected surface to secure; sync already carries
  everything the app needs.
