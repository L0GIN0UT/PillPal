# ADR 0006 — Sync scopes and the privacy projection (Phase 3)

- Status: accepted
- Date: 2026-10-16 (revised after the PR #12 reviews)
- Scope: TZ §2.1, §2.5, §4 (sync); backend `sync_changes`, `app/services/changes.py`,
  `scopes.py`, `sync.py`, `sync_pull.py`, `app/domain/privacy.py`; app sync engine,
  applier, outbox pusher, drift schema v4
- Related: ADR 0005 (roles and access matrix), ADR 0010 (pending deletion),
  `backend/README.md` (sync protocol), `docs/phase3-plan.md` (milestones 3.3, 3.6, 3.7)

## Context

Phase 1 journals every change in `sync_changes(user_id, seq, entity, entity_id, op)` and
serializes writers per user with `pg_advisory_xact_lock(owner)`, so a pull cursor never
skips a row committed later with a smaller `seq`. Loaders filter by
`Profile.owner_user_id == user_id`, and the client reconciles a rejected push by reading
the entity over REST.

Phase 3 needs pulls that mix own and shared profiles, each with its own role, server-side
redaction for projected roles, safe handling of writes relatives may not make, and eviction
when access ends or narrows — without a REST fallback for relatives.

## Decision

### 1. Journal keyed by profile; locks keyed by owner

- `sync_changes.profile_id` (FK `profiles.id` ON DELETE CASCADE) replaces `user_id`
  (revision `0007_sync_changes_scope`). `op` gains `privacy` (journal only).
- `record_change(session, profile_id, …)` journals into the affected profile's scope and
  **asserts that the lock of the scope's owner is held** in this transaction (locked owners
  are tracked in `session.info`); otherwise it raises. The "seq order = commit order per
  owner" invariant is enforced, not conventional.
- `lock_journal(session, owner_ids)` takes `pg_advisory_xact_lock` per owner in sorted
  order. All scopes of one owner share one lock, as today.
- Push resolves owners **only through profiles accessible to the caller**
  (`resolve_batch_owners`); ids that do not resolve are not locked (no lock on foreign
  owners, no timing oracle) and their mutations are rejected `not_found`. REST resolves
  through `lock_for_profile`.
- **After locking, owners are re-read.** If one changed (the D1 transfer, ADR 0005 §5), the
  transaction rolls back and retries, at most 3 times (then `503 retry_later`). The
  transfer itself locks the old and the new owner.

### 2. Scoped pull

`POST /v1/sync/pull {"cursors": {"<profile_id>": seq, …}, "limit": n}` — 1 to 50 cursors,
limit capped at 500, one `REPEATABLE READ` snapshot per page:

- `scopes`: **every** accessible scope (`role`, `kind`, `archived`, `archive_purge_after`,
  `owner_last_seen_at` for foreign self scopes, floored to the hour (D5), and `cursor` for
  requested ones). Granted profiles appear only while the grant is active; archived
  profiles only to owner and guardians. Owned tombstoned scopes appear only while the sent
  cursor is below the tombstone's `seq`, then move to `revoked`. A user has at most
  `MAX_ACCESS_SCOPES_PER_USER` (100) scopes.
- `revoked`: requested scopes the caller cannot access; never-existed, foreign, revoked,
  inactive and deleted look the same.
- `changes`: only for scopes present in `cursors`. The client adds new scopes from `scopes`
  with cursor 0 on its next request; with more than 50 scopes it pulls groups of 50, each
  to completion. Nothing restarts from 0 by omission.
- **Cursor:** for each requested scope, the max `seq` of that scope's journal rows **read**
  in the page (`LIMIT limit+1` probe excluded). For `editor` and `viewer` the journal rows of
  a `hidden` medication, of its schedules and of its dose events are **filtered out in the
  read itself** (SQL, not after it), so they are not read and cannot move the cursor:
  cursor movement alone must not tell a relative that something hidden happened. The one
  exception is the medication's `privacy` rows, which are read because the narrowing delete
  is built from them. What the read returns but the projection still drops (a redacted or
  suppressed change) does advance the cursor, so `has_more` never loops. The read is a
  `LATERAL` per scope (`ORDER BY seq LIMIT limit+1` through `(profile_id, seq)`) and an
  outer `ORDER BY seq LIMIT limit+1`. Safe because each scope is serialized by its owner's
  lock.
- **Backfill marker.** A grant stores `granted_seq`, the scope's journal head, read in
  `accept_invite` while holding the owner's journal lock (so a narrowing committed
  concurrently with the accept is either below `granted_seq` or after it, never both).
  `created_at` cannot be used: `seq` is allocated at INSERT, not at commit. A pull of a
  projected scope from cursor 0 returns `ScopeOut.backfill_until`, the newest readable
  `seq` in that snapshot; the client echoes it as `backfill_until[profile_id]` in every
  request (optional field) until the scope's cursor reaches it, when the response carries
  `null`. For projected roles the *floor* of a request is `max(granted_seq, backfill_until)`;
  see §4.
- The per-entity collapse is kept per scope; the page is then ordered by entity rank
  (profile, medication, schedule, dose event) so parents precede children.

`GET /v1/sync/pull` (owner scopes, one cursor) stayed until the app switched (3.6) and was
removed in 3.10 together with its service function; `POST /v1/sync/pull` is the only pull.

### 3. Privacy projection (pure, `app/domain/privacy.py`)

Applied to **every** relative-facing output: pull changes, `current` in push results
(including `ignored_stale`), and the data behind the relative's PDF. Full-access roles get
entities unchanged.

| Entity | `shared` | `anonymous` | `hidden` |
|---|---|---|---|
| Medication | full | `{id, profile_id, privacy, tz_mode, fixed_tz, redacted: true}` | not returned |
| Schedule | full | `{id, medication_id, redacted: true, rule: {v, kind, start_date, end_date, weekdays?, interval_days?, times: [{time}]}}` (no doses; course dates are needed to expand occurrences and are disclosed on the invite-create disclosure screen) | not returned |
| Dose event | without `note`, `device_id` | without `note`, `device_id` | not returned |
| Profile | `{id, kind, display_name, timezone}` | | |
| Change envelope | `updated_by_device = null` | | |

A test classifies every field of `MedicationOut`, `ScheduleOut`, `DoseEventOut`,
`ProfileOut`, `Change` and `ScopeOut`; OpenAPI carries `MedicationRedacted` and
`ScheduleRedacted` for the app's contract test.

### 4. Privacy changes

- The medication is journaled with op `privacy`; its schedules are re-journaled; its dose
  events are re-journaled only on `hidden` ↔ visible transitions (their projection is the
  same for `shared` and `anonymous`).
- A narrowing to `hidden` reaches projected roles as a medication `delete` (children
  skipped), only if **all** hold: the `privacy` row's `seq` is above the floor
  (`max(granted_seq, backfill_until)`, §2), and the medication's first journal row is at or
  below the cursor the client sent. So nothing from before the grant or inside the
  client's backfill is ever deleted (such a client never held it, and a delete would reveal
  the id and the number of hidden medications), and neither is a medication created after
  the cursor (never delivered, so a delete would leak a hidden id). A hostile client that
  sends a smaller floor gets at most what its grant already allows. Residual, accepted: a
  medication that was `shared` after the grant and `hidden` again later can produce a
  delete the client never needed; the client was entitled to see that id. Events are
  journaled again only on `hidden` to visible: on the way to `hidden` they would all be
  skipped on the way out. Re-journaling on widening is what delivers a medication that
  became visible again, so the filter above loses nothing.
- **Tombstones of history.** For projected roles an `op=delete` change whose `seq` is at or
  below the floor is not sent: a backfill never carries the tombstones of entities deleted
  before the grant or inside the backfill.
- **Redacted envelope.** For an `anonymous` medication and its schedules the envelope
  carries `client_updated_at = null` and, on a tombstone, `deleted_at = null`: they show
  time and status only, not when it was edited or deleted. Relatives never write redacted
  entities, so they need no conflict key for them; `op` alone says "delete".

### 5. Access ends or changes

- **Revoked, inactive (ADR 0010), deleted or purged:** the scope leaves `scopes`. Server
  access ends at once.
- **Archived (D1):** `archived: true` for owner and guardians.
- **Role change** (including guardian → owner at the D1 transfer): see client rules.

### 6. Writes by relatives (sync push)

The server loads the target row **without** an access filter, decides access and privacy,
and only then runs LWW; an upsert carrying the id of an entity the caller cannot see never
reaches the create branch (no `integrity_error` oracle). Rejections use explicit codes
`Rejected("not_found" | "forbidden" | "read_only" | "forbidden_field")`, distinct from
`parent_not_found`.

**Editors, first match wins:**

| # | Condition | Result |
|---|---|---|
| 1 | entity or its medication is `hidden` or `anonymous`, or not in an accessible scope | upsert of an existing id: `not_found`; **delete: `applied` (no-op, as for a missing id)**; new schedule or dose event under such a medication: `parent_not_found` (as under a missing or foreign one) |
| 2 | profile upsert or delete | `read_only` + `current` |
| 3 | dose event of any type (D3) | `forbidden` + `current` |
| 4 | delete of a medication or schedule (D3) | `forbidden` + `current` |
| 5 | medication upsert changing `privacy`, or a new medication not `shared` | `forbidden_field` + `current` |
| 6 | otherwise | LWW as today |

**Viewers:** rule 1, then `forbidden` + `current` for any write on a visible entity.
**Guardians:** full access, except a profile delete of a non-archived managed profile
(only its owner deletes it) → `forbidden` + `current`.
**Archived scopes:** owner and guardians get `read_only` + `current`; purging an archive is
a REST call, not a sync op. `current` is always the projected state for the caller's role.

### 7. Client rules for foreign scopes

1. Never call REST for a foreign scope (the Phase 2 reconcile-by-GET would see 404 and
   tombstone a live entity forever).
2. `forbidden`, `forbidden_field`, `read_only`: apply `current` over the local row; drop the
   outbox entry.
3. `not_found`: hard-delete the entity and its children locally (no tombstone) and drop
   their outbox entries. Safe: an entity still visible in projected form was narrowed
   after the client's cursor, so its re-journaled rows arrive on the next pull.
4. A pulled row that is `redacted`, a medication whose `privacy` differs from the local one,
   or a `delete` **overrides pending local mutations** of that entity and its children and
   drops those outbox entries (otherwise a pending edit would keep full names on a
   relative's device after a narrowing).
5. Deletes are hard deletes; dose events are overwritten (notes stripped).
6. States from pull or push results (including the background flush) whose scope is not in
   `access_scopes` are discarded.
7. Any local scope missing from the latest `scopes` is evicted (rows and outbox entries;
   the outbox carries `profile_id`).
8. **Role change** seen on a page: evict the scope before applying the page, drop that
   scope's changes from the response, store cursor 0.
9. A foreign scope without a successful pull for `ACCOUNT_DELETION_GRACE_DAYS` is evicted.
10. Push and refresh run under one drift sync lease shared by all isolates, with fencing
    (ADR 0001 addendum, 3.7); a refresh repeated within 30 s after a crash is idempotent on
    the server (ADR 0010 §1).

### 8. Compatibility

`Change` gains `scope`; `ScopeOut` is new; `ProfileData` gains optional alert fields with
keep-on-absent semantics. drift v4 turns the old global `pullCursor` into the cursor of
every local profile (all owned before 3.6; `seq` is global). `GET /v1/sync/pull` was removed in
3.10. Downgrade of `0007` restores
`user_id` from the owner and converts `privacy` rows to `upsert`.

## Consequences

- One query per pull page with index `(profile_id, seq)`.
- A privacy change costs one journal row per schedule (and per event only when hidden
  changes), bounded by the medication's history.
- A relative's device holds only projected data; a lost phone leaks at most what the owner
  chose to share, and stale copies age out after the grace period.
- Remote wipe of a device that never syncs again is impossible; the privacy policy says so.

## Alternatives considered

- **Journal per user with fan-out:** writes cost O(relatives); grants need backfill copies.
- **Project at write time:** two versions of every row and rewrites on every privacy change.
- **Lock per profile:** a batch touching several profiles of one owner would need many
  locks, and the old single-cursor pull would be unsafe during the transition.
- **REST reconcile for relatives:** a second projected surface, and 404 is ambiguous
  between "hidden" and "deleted".
- **Reset the scope cursor to 0 on every `not_found`:** correct but re-downloads the scope's
  whole history for one rejected write.
