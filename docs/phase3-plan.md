# Phase 3 — Relatives («Близкие») — delivery plan

Source: `docs/TZ.md` §1, §2.1 (per-medication privacy), §2.3, §2.5, §2.6 (account deletion), §3, §4,
§5 "Фаза 3". Rules: `.claude/rules/privacy.md`, `security.md`, `testing.md`.
ADRs: 0005 (relatives and permissions), 0006 (sync scopes and privacy projection), 0007 (missed-dose
detection), 0008 (push delivery), 0009 (invite links), 0010 (account deletion grace and restore).
Baseline: `main` = `e0c7a21`. Phase 1 is done. **Phase 2 is complete**: 2.0–2.5 are merged on `main`.

Constraints:
- Flutter/Dart cannot run in the Claude sandbox. CI verifies them, and `app-scaffold.yml` regenerates `app/pubspec.lock` when a dependency is added: edit `pubspec.yaml`, delete the lock, push.
- There are no real push credentials yet (Firebase project, APNs key, RuStore project). Senders must be pluggable, disabled when unconfigured, and faked in tests. Android must build without `google-services.json`.
- Backend tests run on real PostgreSQL 16 and Redis 7. Only push-provider HTTP is mocked, because it is a true external.
- No Phase 4/5 work: no catalog, no OAuth, no data export endpoint, no regional client routing. Formal consent documents stay in Phase 5, but the disclosure version of each grant is recorded now (privacy rule 6).

Each milestone is one PR into `main`, merged only with green CI, in the order of the milestone table.
Phase 2 is merged, so app milestones are not blocked by it; app milestones that change `app-emulator.yml`
or `.github/scripts/emulator/` go one at a time to avoid conflicts on those files.

## Requirements (restated)

- **Symmetric links.** Every person has their own account. A profile owner grants another account `view` or `view+edit` on one profile, by invite link or QR. The invitee confirms. Links never cross regions.
- **Managed profiles** (grandma without a smartphone, child, pet) are run by guardian accounts. Reminders fire on guardians' devices. A profile can have more than one guardian.
- **Per-medication privacy** (`shared` / `anonymous` / `hidden`) is enforced server-side on every relative-facing path: API, sync pull, push results, missed-dose push (at enqueue and at send), shared PDF. `anonymous` exposes time and status (plus the course dates needed to expand the schedule).
- **Server-side missed-dose detector** (ARQ). When an occurrence is still unmarked X minutes after it is due (default 30, configurable), relatives get a push: one per occurrence per recipient, no medical data in the payload.
- **Push** via FCM, APNs, and RuStore Push (RU only, devices without GMS).
- **Soft limits** (≈3 relatives, number of PDF reports) live behind a feature flag that stays off.
- **Account deletion with a grace period** (D2): deletion first archives the account for 30 days with restore, then erases it.

## Assumptions

- No installation or deployment exists outside dev and CI: there is no CD, and ADR 0002 says "no installation exists yet". So protocol changes need no long deprecation window. Alembic revisions must still be reversible, and journal backfills are allowed in one step (they would be split if a stand existed).
- "Relative" means anyone holding a grant on a profile. Guardians of a managed profile have full access, including `hidden` medications: privacy protects the profile from relatives, not from the people who run it.
- Grants, invites, alerts and push-outbox rows get **server-generated ids**: none of them can be created offline. Invites take a client UUID so a lost create response can be retried safely. Medications, schedules and dose events keep client UUIDs as before.
- `docs/TZ.md` and `README.md` are not edited.

## Key decisions (fixed in ADRs 0005–0010)

1. **Roles** (ADR 0005). `owner` = `profiles.owner_user_id` (for a managed profile, its primary guardian); `guardian` (managed only); `editor` ("view+edit"); `viewer` ("view"). Full access: owner, guardian. Projected: editor, viewer. **Editors edit `shared` medications and schedules only: no dose events, no deletes** (D3).
2. **The sync journal is keyed by profile (scope)** (ADR 0006). One cursor per scope. The lock key stays the **owner user id of the scope**; owners are resolved only through accessible profiles and re-checked after locking.
3. **The privacy projection is a pure domain function** applied to every relative-facing output: pull pages, `current` in push results, PDF data. Access and privacy are checked before LWW.
4. **REST CRUD stays limited to full-access roles.** Relatives read and write only through sync; clients never call REST for foreign scopes.
5. **The detector is windowed** (ADR 0007): one tick at a time (session advisory lock), per-batch journal locks, the watermark committed last, each occurrence evaluated once at its final due + X, late undos re-evaluated.
6. **Push payloads carry ids only** (ADR 0008); access is re-checked at send time; tokens are registered only by users who need relative alerts.
7. **Invite links** (ADR 0009): `https://{link_host}/i#<token>`; host config-driven with the placeholder `*.pillpal.invalid` until the owner picks a domain (D6). Guardian invites live 24 h.
8. **Account deletion is an archive with restore** (ADR 0010, D2): restore needs the password, a restore ticket and a one-time e-mail code; after `ACCOUNT_DELETION_GRACE_DAYS` (30) an hourly job erases.
9. **A managed profile whose owner goes away becomes a read-only archive** for its co-guardians (ADR 0005 §5, D1); kept `MANAGED_ARCHIVE_RETENTION_DAYS` (365) after the owner's erasure, then purged.

---

## Data model

### New tables

New ORM modules (`models.py` would exceed 400 lines): `backend/app/db/relatives.py`, `backend/app/db/push.py`, `backend/app/db/alerts.py`, imported by `app/db/__init__.py` for Alembic.

**`profile_grants`** (revision `0004_profile_grants`)

| Column | Type | Constraint |
|---|---|---|
| `id` | uuid | PK (server-generated) |
| `profile_id` | uuid | FK `profiles.id` ON DELETE CASCADE |
| `grantee_user_id` | uuid | FK `users.id` ON DELETE CASCADE |
| `role` | text | CHECK `role IN ('viewer','editor','guardian')` |
| `notify_missed` | bool | NOT NULL DEFAULT true (grantee's choice) |
| `disclosure_version` | int | NOT NULL, copied from the invite (what the owner was shown when granting) |
| `invite_id` | uuid null | provenance only, no FK (invites are purged) |
| `created_at`, `updated_at` | timestamptz | NOT NULL DEFAULT now() |

- UNIQUE `(profile_id, grantee_user_id)`; index `(grantee_user_id)`; index `(profile_id, role, created_at)` (earliest co-guardian, D1).
- Trigger `profile_grants_guard` (BEFORE INSERT, and BEFORE UPDATE OF `role`) rejects `grantee_user_id = profiles.owner_user_id`, `guardian` on a non-managed profile and grants on a tombstoned profile; `0009_profile_archive` adds "not on an archived profile". `notify_missed` updates are not guarded, so PATCH works on archives. A trigger on `profiles` (BEFORE UPDATE OF `owner_user_id`) rejects an owner who still holds a grant on the profile.
- Revocation and leaving are a hard DELETE; no history of links is kept.
- A grant is **active** only while neither its grantee nor the profile's owner is `pending_deletion` (D2). Inactive grants are kept (restore brings them back) and listed to the owner as `active: false` so they can be revoked during the grace period; they give no access and no alerts. Activity is part of the access predicate, not a stored flag.

**`invites`** (revision `0005_invites`)

| Column | Type | Constraint |
|---|---|---|
| `id` | uuid | PK, client UUID (idempotent create) |
| `profile_id` | uuid | FK `profiles.id` ON DELETE CASCADE |
| `created_by_user_id` | uuid | FK `users.id` ON DELETE CASCADE |
| `role` | text | CHECK in (`viewer`,`editor`,`guardian`) |
| `disclosure_version` | int | NOT NULL, version of the disclosure screen the owner confirmed |
| `token_hash` | text | UNIQUE, `sha256(token)` hex; the token is 256 bits (`secrets.token_urlsafe(32)`) |
| `created_at` | timestamptz | NOT NULL DEFAULT now() |
| `expires_at` | timestamptz | NOT NULL, CHECK `expires_at > created_at`; TTL 24 h for `guardian`, 7 days otherwise |
| `consumed_at` | timestamptz null | single use |
| `consumed_by_user_id` | uuid null | FK `users.id` ON DELETE SET NULL; set to NULL by the retention cron after `INVITE_REPLAY_WINDOW_SECONDS` (24 h) |
| `revoked_at` | timestamptz null | |

- CHECK `NOT (consumed_at IS NOT NULL AND revoked_at IS NOT NULL)`; partial index `(profile_id) WHERE consumed_at IS NULL AND revoked_at IS NULL` (active-invite cap).
- Guard trigger: guardian only on managed profiles; `0009_profile_archive` adds "not on an archived profile".
- Retention: deleted 30 days after expiry, consumption or revocation. Closed in 3.3b: `app.jobs.retention.cleanup_retention` nulls `consumed_by_user_id` after `INVITE_REPLAY_WINDOW_SECONDS` and purges old invites (ARQ cron in 3.4).

**`push_tokens`** (revision `0010_push_tokens`)

| Column | Type | Constraint |
|---|---|---|
| `id` | uuid | PK (server) |
| `user_id`, `device_id` | uuid, text | FK → `devices(user_id, device_id)` ON DELETE CASCADE; UNIQUE `(user_id, device_id)` |
| `provider` | text | CHECK in (`fcm`,`apns`,`rustore`) |
| `token` | text | format CHECK per provider (APNs `^[0-9a-f]{64,200}$`; FCM/RuStore `^[A-Za-z0-9_:-]{1,4096}$`); UNIQUE `(provider, token)`; a token moving to another account is reassigned |
| `apns_environment` | text null | CHECK `(provider = 'apns') = (apns_environment IS NOT NULL)`, `sandbox`/`production` |
| `created_at`, `updated_at`, `last_success_at` | timestamptz | |

At most `PUSH_MAX_TOKENS_PER_USER` (10) per user (409 `too_many_push_tokens`), so the server cannot be used as an amplifier.

**`push_outbox`** (revision `0011_push_outbox`): transactional outbox, at-least-once.

| Column | Type | Constraint |
|---|---|---|
| `id` | bigserial | PK |
| `push_token_id` | uuid | FK `push_tokens.id` ON DELETE CASCADE |
| `recipient_user_id` | uuid | FK `users.id` ON DELETE CASCADE |
| `subject_profile_id` | uuid null | FK `profiles.id` ON DELETE CASCADE |
| `subject_medication_id` | uuid null | FK `medications.id` ON DELETE CASCADE (send-time privacy re-check) |
| `kind` | text | CHECK in (`missed`,`resolved`,`link_accepted`,`link_restored`) |
| `dedupe_key` | text | UNIQUE (e.g. `missed:{alert_id}:{push_token_id}`) |
| `payload` | jsonb | built only from `PushPayload`; CHECK keys ⊆ `{v,t,a,p,m,g,s}` |
| `status` | text | CHECK in (`pending`,`sent`,`dropped`) |
| `attempts` | int | CHECK `>= 0` |
| `next_attempt_at`, `created_at`, `sent_at` | timestamptz | |
| `last_error_code` | text null | provider error code or `access_changed`/`provider_disabled`, never a token |

Index `(next_attempt_at) WHERE status = 'pending'`. Retention: `sent` rows 24 h, others 7 days.

**`missed_dose_alerts`** (revision `0012_missed_dose_alerts`)

| Column | Type | Constraint |
|---|---|---|
| `id` | uuid | PK (server) |
| `profile_id` | uuid | FK `profiles.id` ON DELETE CASCADE |
| `medication_id` | uuid | FK `medications.id` ON DELETE CASCADE |
| `occurrence_key` | text | CHECK `char_length <= 64` |
| `due_at` | timestamptz | final due instant |
| `variant` | text | CHECK in (`missed`,`unconfirmed`) |
| `detected_at` | timestamptz | |
| `resolved_at` | timestamptz null | set when a late `taken`/`skipped` arrives |

UNIQUE `(profile_id, occurrence_key)`. Retention: 72 h (dedupe and `resolved` never need more than the 6 h catch-up + 2 h staleness). The revision also creates `detector_state` (`name text PK`, `watermark timestamptz NOT NULL`), seeded with `('missed_dose', now())`.

### Changed tables

| Table | Change | Revision |
|---|---|---|
| `profiles` | `missed_alert_minutes int NOT NULL DEFAULT 30 CHECK (BETWEEN 5 AND 720)`, `missed_alerts_enabled bool NOT NULL DEFAULT true`; synced fields. | `0006_profile_alert_settings` |
| `sync_changes` | Adds `profile_id uuid NOT NULL` FK `profiles.id` ON DELETE CASCADE, index `(profile_id, seq)`; backfill entity → profile; drops `user_id` and its index; `op` CHECK adds `privacy` (journal only, never on the wire; `SYNC_OPS` and `changes.Op` updated). Downgrade restores `user_id` from the owner and converts `privacy` rows to `upsert`. | `0007_sync_changes_scope` |
| `users` | `deletion_requested_at`, `erase_after` (both or neither, `erase_after > deletion_requested_at`, partial index on `erase_after`), `tokens_not_before timestamptz null` (access JWTs with older `iat` refused); `email_codes.purpose` CHECK adds `restore_account`. `pending_deletion` ⇔ `deletion_requested_at IS NOT NULL`. | `0008_user_deletion_grace` |
| `profiles` | `archived_at`, `archive_reason` (`owner_pending_deletion` \| `owner_erased`), `archive_purge_after` (set at `owner_erased`); CHECKs: both-or-neither, managed only, `archive_purge_after` only with `owner_erased`. Replaces the grant and invite guard functions to refuse archived profiles. Server-controlled, never read from input. | `0009_profile_archive` |
| `dose_events` | Partial indexes `(snooze_until) WHERE type = 'snoozed'` and `(recorded_at) WHERE type = 'undo'` for the detector. Append-only trigger untouched. | `0013_dose_events_detector_indexes` |
| `medications.privacy` | Unchanged column, now enforced on relative paths. Default `shared` (ADR 0003 §7). | — |

### Deletion, retention and inventory (privacy.md rule 7)

Account deletion has two stages (ADR 0010):

- **Request (`DELETE /v1/me`)**, one transaction, `SELECT … FOR UPDATE` on the user row, then the user's journal lock: set `deletion_requested_at`, `erase_after = now + grace − job interval`, `tokens_not_before = now`; revoke all refresh-token families; revoke open invites; archive owned managed profiles `WHERE archived_at IS NULL` with `owner_pending_deletion`; (from 3.4) delete push tokens and mark pending `push_outbox` rows of the user's profiles `dropped/access_changed`; mail "deletion requested, erased on …; if this wasn't you, restore and change your password". Nothing is erased.
- **Restore** (`POST /v1/auth/restore`, ticket + e-mail code): clears the columns, sets `tokens_not_before = now`, un-archives `owner_pending_deletion` profiles `WHERE deleted_at IS NULL`; mail "account restored"; (from 3.4) `link_restored` push to owners of profiles the account holds grants on.
- **Hard erase** (`erase_account`, called by the hourly job for `erase_after ≤ now`, row lock inside each user's transaction, looping until no due row remains):
  - **D1 transfer first:** each owned managed profile with an *active* co-guardian (earliest by `created_at, id`, not `pending_deletion`) moves to that guardian (their grant deleted), its viewer/editor grants are deleted, `archive_reason = owner_erased`, `archive_purge_after = now + MANAGED_ARCHIVE_RETENTION_DAYS`, `updated_by_device` cleared on its rows; journal locks of old and new owner in sorted order;
  - then deletes `push_outbox`, `push_tokens`, `missed_dose_alerts`, `profile_grants`, `invites` (others' `consumed_by_user_id` → NULL), `sync_changes` of still-owned scopes, and the existing Phase 1 rows (dose events via `pillpal.purge`, schedules, medications, profiles, devices, refresh tokens, e-mail codes, user).
- **Archive purge** (deleting an archive after `owner_erased`, or `archive_purge_after` reached in `cleanup_retention`): a hard purge of the profile, its medications, schedules, dose events (`pillpal.purge`), journal rows, alerts and grants — not a tombstone. Devices see the scope leave `scopes` and evict it.
- **Retention** (`cleanup_retention`, daily): invites 30 days after end of life (`consumed_by_user_id` nulled after 24 h), alerts 72 h, outbox `sent` 24 h / other 7 days, push tokens without success for 270 days, archives at `archive_purge_after`.
- **Inventory guard:** `backend/app/services/personal_data.py` declares `TABLE_CLASSIFICATION: dict[str, TableInfo(kind: personal|medical|system, owner_column)]` (the owner column serves Phase 5 export) and `REDIS_KEYSPACES` (restore tickets, refresh reuse cache, rate limits, ARQ). A test fails on any unclassified table. The needle test `test_account_deletion_erases_all_owned_rows` runs the full path (request → grace on a fake clock → job) and covers grant, invite, token, alert, outbox and archive-purge rows.
- **App:** `AppDatabase.wipeAccountData` covers the new drift tables. The deleting device wipes local data at once; a restore re-pulls. Relatives' devices evict a foreign scope that has had no successful pull for `ACCOUNT_DELETION_GRACE_DAYS` (stated in the privacy policy as a limitation: remote wipe is impossible).

---

## Access model and privacy projection

| Capability | owner (self) | owner (managed) | guardian | editor | viewer |
|---|---|---|---|---|---|
| Read profile (name, zone) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Read alert settings | ✓ | ✓ | ✓ | — | — |
| `shared` medications | full | full | full | full | full |
| `anonymous` medications | full | full | full | redacted | redacted |
| `hidden` medications | full | full | full | — | — |
| Create/update medications and schedules | all | all | all | `shared` only; `privacy` immutable; new meds `shared` | — |
| Delete medications and schedules | all | all | all | — (`forbidden`, D3) | — |
| Record dose events | all | all | all | — (`forbidden`, D3) | — |
| Edit profile, alert settings, privacy | ✓ | ✓ | ✓ | — | — |
| Invites and grants management | ✓ | ✓ | — | — | — |
| Delete profile | — (self protected) | ✓ | — | — | — |
| Local reminders | ✓ | ✓ | ✓ (per-device toggle) | — | — |
| Missed-dose push | — (local reminders) | ✓ when the profile has co-guardians | ✓ | ✓ (opt-out) | ✓ (opt-out) |
| Owner's last sync time (D5, rounded to the hour) | — | — | ✓ (self scopes only) | ✓ | ✓ |
| Leave (delete own grant) | — | — | ✓ | ✓ | ✓ |

**Archived managed profile (D1)** overrides the matrix, including for the (transferred) owner:

| Capability | `owner_pending_deletion` | `owner_erased` |
|---|---|---|
| Read (Today, History, PDF) | guardians only (owner cannot act) | owner and guardians |
| Any write, invites, grants, role changes | rejected (`read_only`) | rejected (`read_only`) |
| Reminders, missed-dose detection | none | none |
| Guardians | may only **leave** | may leave; owner or any guardian may **delete (purge)** |
| Viewer/editor grants | inactive | deleted at transfer |
| Retention | until restore or erasure | `archive_purge_after` (shown on the banner) |

**Pending-deletion account (D2):** its self profile and non-archived owned profiles are invisible to relatives, its own grants are inactive, it gets no pushes, its profiles are not monitored, and every token path (`_issue_tokens`, `refresh`, `get_current_user`) refuses it.

**Projection** (`backend/app/domain/privacy.py`, pure, ~100% covered), applied to pull changes, push-result `current`, and the relative's PDF data:

- **Medication, `anonymous`:** `{id, profile_id, privacy, tz_mode, fixed_tz, redacted: true}`.
- **Schedule of an `anonymous` medication:** `{id, medication_id, redacted: true, rule: {v, kind, start_date, end_date, weekdays?, interval_days?, times: [{"time": "HH:MM"}]}}`. Course dates and kind are exposed because the client must expand occurrences; the invite-create disclosure screen says so.
- **Dose event, projected roles:** without `note` and `device_id`.
- **Profile, projected roles:** `{id, kind, display_name, timezone}`.
- **Change envelope, projected roles:** `updated_by_device = null`.
- **`hidden`:** never returned; a narrowing emits a medication `delete`; on a backfill from cursor 0 such deletes are suppressed (they would reveal hidden ids).

A field-classification test covers `MedicationOut`, `ScheduleOut`, `DoseEventOut`, `ProfileOut`, `Change` and `ScopeOut` (**`ScopeOut` is classified in 3.3**, where it is introduced; 3.2 classifies the other five); OpenAPI gets `MedicationRedacted` / `ScheduleRedacted` schemas for the app's contract test. The app parses redacted rows with nullable `name` and a placeholder dose (`parseScheduleRow`); the UI never renders doses of redacted schedules.

The relative's day view and the archive screen are dose screens: no ads, and no new analytics events carrying role, privacy or medication ids (privacy rule 8).

---

## Sync protocol changes (milestone 3.3)

**Journal and locks.**
- `record_change(session, profile_id, entity, entity_id, op)` journals into the affected profile's scope and **asserts that the scope owner's lock is held** (owners locked in this transaction are tracked in `session.info`); otherwise it raises.
- `lock_journal(session, owner_ids)` takes `pg_advisory_xact_lock` per owner in sorted order.
- Push resolves owners **only through profiles accessible to the caller** (`resolve_batch_owners`: ids, payload `profile_id`/`medication_id`, in-batch parents). Ids that do not resolve are not locked and are rejected `not_found`. REST resolves through `lock_for_profile`.
- After locking, owners are **re-read**; if any changed (D1 transfer), the transaction rolls back and retries (at most 3 times, then `503 retry_later`).
- All `record_change` call sites move to `profile_id`: `services/auth.py` (self profile at registration), `entities.py`, `dose_events.py`, `sync.py`; `erasure.py` deletes by scope.

**Scoped pull: `POST /v1/sync/pull`** (requires `X-Device-ID`; touches `devices.last_seen_at`, at most one write per 5 min; one `REPEATABLE READ` snapshot per page).

```jsonc
// request
{"cursors": {"<profile_id>": 123, "...": 0}, "limit": 200}   // 1..50 cursors, limit ≤ 500 (server cap)
// response
{
  "scopes":  [{"profile_id": "…", "role": "owner|guardian|editor|viewer", "kind": "self|managed",
               "archived": false, "archive_purge_after": null,
               "owner_last_seen_at": "2026-10-16T08:00:00Z" /* foreign self scopes only, floored to the hour */,
               "cursor": 456 /* null when not in this request */}],
  "revoked": ["<profile_id>"],     // requested scopes the caller cannot access (never existed == revoked)
  "changes": [{"seq": 455, "scope": "<profile_id>", "entity": "medication", "id": "…", "op": "upsert|delete",
               "data": {…} | null, "client_updated_at": …, "updated_by_device": … | null, "deleted_at": …}],
  "has_more": false
}
```

- `scopes` lists **every** accessible scope (capped by `MAX_ACCESS_SCOPES_PER_USER` = 100, enforced at accept and managed-profile create). Changes are returned **only for scopes present in `cursors`**: the client adds new scopes from `scopes` with cursor 0 on its next request, and with more than 50 scopes it pulls them in groups of 50, each group to completion. Nothing restarts from 0 by omission.
- Owned tombstoned scopes are listed only while the sent cursor is below the tombstone's `seq`; afterwards they go to `revoked`, so deleted managed profiles do not accumulate.
- The page is `sync_changes JOIN (VALUES (scope, cursor)…) WHERE seq > cursor ORDER BY seq LIMIT limit+1`. **Each scope's cursor is the max `seq` of that scope's journal rows read in the page** (the `limit+1` probe row excluded), whether or not the projection dropped them, so a page made only of hidden rows still advances. The per-entity collapse is kept per scope; the page is then ordered by entity rank (profile, medication, schedule, dose event) so parents precede children.
- **Privacy change:** the medication is journaled with op `privacy`; its schedules are re-journaled; dose events are re-journaled only on `hidden` ↔ visible transitions (their projection is the same for `shared` and `anonymous`).
- **Grant revoked, grant inactive (D2), profile deleted or purged:** the scope leaves `scopes` (and is in `revoked` if its cursor was sent). Server-side access ends at once.
- **Archived scope:** listed with `archived: true` to owner and guardians.

**Push results for relatives.**
- Order of checks: load the target row **without** an access filter, decide access and privacy, and only then run LWW. An upsert carrying the id of an existing entity the caller cannot see never reaches the create branch (no `integrity_error` oracle).
- New explicit rejection codes `Rejected("not_found" | "forbidden" | "read_only" | "forbidden_field")`, distinct from `parent_not_found`.
- For `forbidden`, `forbidden_field` and `read_only` the result carries `current` = the **projected** server state; `current` of `ignored_stale` results is projected as well.
- **Rule order for editors** (first match wins):
  1. the entity, or its medication, is `hidden` or `anonymous`, or does not exist in an accessible scope → `not_found`;
  2. profile upsert or delete → `read_only`;
  3. dose event (any type) → `forbidden`;
  4. delete of a medication or schedule → `forbidden`;
  5. medication upsert changing `privacy`, or a new medication not `shared` → `forbidden_field`;
  6. otherwise LWW as today.
- **Viewers:** rule 1, then `forbidden` for every write on a visible entity.
- **Guardians:** full access, except deleting a non-archived managed profile (owner only) → `forbidden`.
- **Archived scope:** guardians and owner get `read_only` (with `current`), except the owner's or a guardian's purge after `owner_erased`, which is a REST call (`DELETE /v1/profiles/{id}`), not a sync op. Editors and viewers do not see archived scopes (rule 1).

**Client rules for foreign scopes** (3.6):
- **Never** call REST for a foreign scope.
- `forbidden` / `forbidden_field` / `read_only`: apply `current` over the local row and drop the outbox entry.
- `not_found`: hard-delete the entity and its children locally (no tombstone) and drop the outbox entries of that entity and its children. This is safe: an entity that is still visible in projected form was narrowed after the client's cursor, so its re-journaled rows arrive on the next pull.
- A pulled row that is `redacted`, or a medication whose `privacy` differs from the local one, or a `delete`, **overrides pending local mutations** of that entity and its children and drops those outbox entries.
- Deletes are hard deletes; dose events are overwritten (notes stripped).
- States (pull or push results, including the background flush) whose scope is not in `access_scopes` are discarded.
- Any local scope missing from the latest `scopes` is evicted (not only those in `revoked`); eviction removes the scope's rows and outbox entries (outbox gains `profile_id`).
- **Role change** detected on a page: (a) evict the scope before applying the page, (b) drop that scope's changes from the response, (c) store cursor 0 for it.
- A foreign scope with no successful pull for `ACCOUNT_DELETION_GRACE_DAYS` is evicted.

**Compatibility.** `GET /v1/sync/pull` (owner scopes, one cursor) stays until the app switches in 3.6 and is removed in 3.10. `Change` gains `scope`; `ProfileData` gains optional `missed_alert_minutes` / `missed_alerts_enabled` with keep-on-absent semantics. drift v4 turns the old global `pullCursor` into the cursor of every local profile (all owned before 3.6; valid because `seq` is global).

---

## Missed-dose detector (milestone 3.5)

**Shared semantics first (3.1).** `docs/spec/dose-state.md`: effective mark (ADR 0003 §6: last non-undone `taken`/`skipped` by `at`, tie on the larger id); latest non-undone snooze (by `at`, tie on the larger id, as `occurrenceStates` in the app); `due = max(occurrence instant, latest snooze_until)`; `missed(T, X) ⇔ no mark ∧ T ≥ due + X`. Vectors in `spec/dose-state-vectors/`, Python reference `app/domain/dose_state.py`, Dart port in `pillpal_core`.

**Tick** (ARQ cron every 60 s):
1. Session-level `pg_try_advisory_lock(DETECTOR_LOCK_KEY)` held for the whole tick; if not acquired, skip. Read the watermark `w`; window `[w, e)`, `e = min(now, w + 10 min)`; after downtime > 6 h, `w` jumps to `now − 6 h` (logged as a count).
2. Eligible profiles, keyset-paged (500): live, not archived, owner not `pending_deletion`, `missed_alerts_enabled`, and managed with co-guardians or with an active grant having `notify_missed`.
3. Per batch, one transaction: `lock_journal(owner_ids)` (sorted) **before** reading events, re-check eligibility under the locks (a deletion request that committed first is seen), then:
   - **A:** occurrences of live schedules of live medications with `instant + X ∈ [w, e)` (engine `expand(rule, schedule_id, tz, w − X, e − X)`), dropping those before `schedules.created_at`;
   - **B:** keys of non-undone snoozes with `snooze_until + X ∈ [w, e)`;
   - **C:** keys of `undo` events with `recorded_at ∈ [w, e)` (late undo of a mark or a snooze);
   - evaluate dose state; alert when unmarked and the final `due + X ≤ e` and (for A/B) `due + X ∈ [w, e)` or (for C) `due + X < e`;
   - `INSERT … ON CONFLICT (profile_id, occurrence_key) DO NOTHING RETURNING id`; recipients: the owner of a managed profile that has co-guardians, guardians, grantees of active grants with `notify_missed` created before `due`; `hidden` → full-access only; never a `pending_deletion` user; one outbox row per recipient token.
   - Invalid rules are skipped and logged with `schedule_id` and an error code only.
4. The watermark moves to `e` in the **last** transaction of the tick; then the session lock is released and `deliver_pushes` is enqueued (the 10 s cron covers a lost enqueue).

Because `record_dose_event` runs under the same owner lock, a late `taken` either commits before the batch reads events (no alert) or after the alert exists (it resolves it). Resolution sends `resolved` to recipients **recomputed by the same rule** (not read from the outbox). Lowering `missed_alert_minutes` can skip occurrences whose new `due + X` already lies before `w` (documented, accepted).

**Offline policy and `unconfirmed` (D5).** The detector never waits for devices. For a `self` profile whose owner's devices were all last seen before the occurrence instant, the alert is `unconfirmed`; the app renders "no confirmation, phone last synced around HH:00" from `ScopeOut.owner_last_seen_at` (floored to the hour, never in a push payload). Managed profiles are always `missed`. 3.7 uploads notification-action marks in the background to keep false alarms rare.

**Time zones (D4).** Server: `fixed` → `fixed_tz`, `local` → `profiles.timezone`. App: **the own self profile uses the device zone (synced to the server by `syncDeviceZone`); every other scope uses `profiles.timezone`** — managed profiles (grandma's 08:00 stays hers) and relatives' self profiles alike. The note in `docs/spec/schedule.md` §3.1 is added in 3.5 and reviewed by `schedule-engine-guardian`. DST stays in the engine.

**Load bounds.** Latency ≤ X + 60 s + delivery; constant queries per batch (statement-counter test); target 10k eligible profiles per tick < 5 s; sharding by `hashtext(profile_id) % N` is a follow-up.

**Worker** (`backend/app/worker.py`): functions `deliver_pushes`, `erase_expired_accounts`; crons `detect_missed_doses` (1 min), `deliver_pushes` (10 s), `erase_expired_accounts` (hourly), `cleanup_retention` (daily). Every job runs inside a wrapper that logs failures with exception **type and frames only** (the HTTP middleware policy), never `str(exc)`; `keep_result=0`; JSON `job_serializer`/`job_deserializer` (no pickle); Redis with password/ACL, not exposed. Compose service `worker` (same image, `arq app.worker.WorkerSettings`, healthcheck `arq --check`). ARQ is in maintenance mode, so jobs are plain `async def f(ctx, …)`.

---

## Push (milestone 3.4)

**Abstraction** (`backend/app/push/`): `PushPayload` (strict, ids and enums only: `v`, `t` ∈ `missed|resolved|link_accepted|link_restored`, `a`, `p`, `m`, `g`, `s`), `PushMessage`, `SendResult` (`OK`, `INVALID_TOKEN`, `RETRY`, `FATAL`), `PushSender` protocol; `FcmSender` (HTTP v1, service-account JWT RS256, OAuth token URL hard-coded `https://oauth2.googleapis.com/token`), `ApnsSender` (HTTP/2, ES256 `.p8`), `RuStoreSender`, `FakePushSender`, `DisabledPushSender`; `build_senders(settings)`. Senders map transport errors to `RETRY` without `str(exc)` (httpx messages contain the APNs token URL); Sentry breadcrumbs exclude URLs.

**Settings:** `FCM_PROJECT_ID`, `FCM_SERVICE_ACCOUNT_JSON[_FILE]` (per-region service account with `roles/firebasecloudmessaging.admin` only), `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_PRIVATE_KEY[_FILE]` (one key per region), `APNS_TOPIC`, `RUSTORE_PROJECT_ID`, `RUSTORE_SERVICE_TOKEN[_FILE]`, `PUSH_MAX_ATTEMPTS=5`, `PUSH_STALE_AFTER_SECONDS=7200`, `PUSH_MAX_TOKENS_PER_USER=10`. `*_FILE` variants read Docker secrets. Validators: a provider partly configured fails in `prod`; **`REGION=eu` with any `RUSTORE_*` set fails startup**. No Firebase Analytics or Crashlytics dependencies.

**Token registration:** `PUT /v1/push-tokens/current {provider, token, apns_environment?}` (X-Device-ID required; format validated; upsert; reassignment from another account deletes the old row — documented accepted risk: whoever holds a device's token can take over its alerts), `DELETE /v1/push-tokens/current`. Logout deletes the token of the device bound to the refresh token (`refresh_tokens.device_id`; logout has no `X-Device-ID`). The deletion request deletes all tokens of the user. **The app registers a token only while the user needs relative alerts**: has an incoming grant, a guardian role, a managed profile with co-guardians, or an open invite; it deletes the token when none remains. Without a token, the Family tab's "new relative" banner (from `GET /v1/grants`) still shows new and restored links.

**Payload and rendering:** Android (FCM/RuStore) data-only high-priority; the app renders from local projected data on channel `relatives_alerts_v1` with `VISIBILITY_PRIVATE` and a generic public version; id in the app range (ADR 0001 §3) derived from the alert id. iOS: alert push with neutral `loc-key` names (`relatives_alert_1`, not "missed_dose"), `thread-id = p`, `apns-collapse-id = a`, `mutable-content: 1`, **no `m`**. Never names, doses, times or occurrence keys.

**Delivery** (`deliver_pushes`): claims up to 200 pending rows `FOR UPDATE SKIP LOCKED` and **re-checks access in the claim query**: recipient and subject owner not `pending_deletion`; subject profile live and not archived; recipient still holds a role on the profile (active grant or owner); for `subject_medication_id`, the recipient's role may still see the medication's current privacy (`hidden` → full access only). Otherwise the row is `dropped/access_changed`. Then `OK` → `sent`; `INVALID_TOKEN` → delete token; `RETRY` → back-off 30 s, 2 min, 10 min, 30 min; `FATAL` → `dropped`; stale or `PUSH_MAX_ATTEMPTS` → `dropped`. Logs: delivery id, provider, status, code.

---

## Invites and deep links

- **Create:** `POST /v1/profiles/{profile_id}/invites {id, role, disclosure_version}` → `{id, role, expires_at, url: "https://{link_host}/i#<token>"}`, token shown once. TTL 24 h for `guardian`, 7 days otherwise; ≤ 5 active per profile; archived profiles refuse (`409 read_only`). Replay of the id → `409 already_exists`; the client then **deletes** that orphaned invite and creates a new one. The create screen discloses what the relative will see: medications by privacy level (with course dates for `anonymous`), the self profile's time zone (follows the phone), and the last sync time (D5).
- **Preview:** `POST /v1/invites/preview {token}` → `{inviter_display_name, profile_display_name, profile_kind, role, expires_at}`.
- **Accept** (never automatic; explicit confirmation, with a prominent warning for `guardian`): locks the invite row; a `UNIQUE(profile, grantee)` conflict → `already_linked` without consuming; otherwise creates the grant (copying `disclosure_version`), consumes the invite and enqueues `link_accepted`. A replay by the same user returns the grant **only if it still exists**, otherwise `invite_used`; a grant is never re-created from a consumed invite.
- **Errors:** `invite_invalid`, `invite_expired`, `invite_used`, `invite_own_profile`, `already_linked`, `relatives_limit_reached`, `too_many_scopes`. Rate-limited per user and IP (the limiter is fail-open; acceptable for 256-bit tokens).
- **Grants API:** `PATCH /v1/grants/{id}` with fields of another role (or mixed) → 422, never partial.
- **Link host (D6):** `PUBLIC_LINK_BASE_URL` per region, placeholder `https://links-{ru,eu}.pillpal.invalid` until the owner picks a domain. `/.well-known/assetlinks.json` and `/.well-known/apple-app-site-association` from Settings (404 when unset; `application/json`; no redirects; in `prod` `ANDROID_CERT_SHA256S` is format-validated and the debug certificate rejected). `GET /i` static landing: no token, no third-party resources, `Cache-Control: no-store`, `Referrer-Policy: no-referrer`, CSP with `frame-ancestors 'none'`, `X-Content-Type-Options: nosniff`.
- **App:** `PILLPAL_LINK_HOSTS`; Android `autoVerify` https intent-filter with Gradle placeholders; iOS associated domains from `Links.xcconfig`; **no custom URL scheme in any build**; `app-release.yml` checks the merged manifest for VIEW filters without `https`; "Paste invite link" fallback; other-region hosts refused.

---

## Account deletion grace and restore (milestone 3.3b, D2)

- **`DELETE /v1/me`** (password-confirmed) → 204; performs the request stage above.
- **Login during grace** (correct password only; wrong password → `401 invalid_credentials`): `403 account_pending_deletion` with `details: {restore_ticket, erase_after}`, and a `restore_account` e-mail code is sent (existing budget: `_new_code_capped`, `_consume_code`). The ticket: 256 bits, `sha256` in Redis, TTL 600 s, single use. Sentry `before_send` scrubs `restore_ticket`; the app never logs error bodies. The envelope gains an optional `details` object (server-generated values only).
- **`POST /v1/auth/restore {restore_ticket, code}`** (rate-limited): locks the user row, re-checks `erase_after > now`, consumes the code, restores (see above), returns a token pair. Missing or wrong code, bad ticket, or past `erase_after` → `401 invalid_token`.
- **Pending checks are centralized** in `_issue_tokens` and `refresh` (no path issues or rotates tokens for a pending user) and in `get_current_user` (`tokens_not_before`).
- **Register during grace:** same `202` and body; the mail to the existing address contains instructions only (no ticket, no link capability). **Password reset** works and does not restore by itself.
- **Erasure job** `erase_expired_accounts` (CLI `python -m app.jobs.account_erasure`; **3.3b must not be deployed without 3.4's scheduler or a cron calling this entry point**): loops over due users in batches, each user in its own transaction with `SELECT … FOR UPDATE SKIP LOCKED` inside it, until none is due; gauge `erasure_overdue_count` (due for more than one interval). Concurrent restore and job → one wins.
- **Margin:** `erase_after = request + grace - 2 x job interval` (one missed run plus the end-of-run blocking retry of skipped, i.e. locked, accounts under `lock_timeout`); the validator requires `grace > 2 x interval`. The restore ticket is bound to the deletion cycle (`deletion_requested_at`), checked under the user row lock.
- **Known limitation until 3.6:** the legacy `GET /v1/sync/pull` (own scopes) and clients that have not yet adopted scoped pull do not learn about a transfer or purge of an archive until they pull scoped; removed in 3.10.
- **Settings:** `ACCOUNT_DELETION_GRACE_DAYS=30` (validator `1..30`), `ACCOUNT_ERASURE_JOB_INTERVAL_SECONDS=3600`, `ACCOUNT_RESTORE_TICKET_TTL_SECONDS=600`, `MANAGED_ARCHIVE_RETENTION_DAYS=365`.
- **Deletion dialog (3.8)** states: relatives lose access at once; data is kept blocked until `erase_after` only to allow restore; what happens to each managed profile (archive for co-guardians, kept `MANAGED_ARCHIVE_RETENTION_DAYS`, or erased); notes in managed profiles stay with co-guardians.

---

## App (milestones 3.6–3.9)

- **Data (3.6):** drift v4: `access_scopes` (profile_id, role, kind, archived, archive_purge_after, owner_last_seen_at, cursor, last_pulled_at), `relative_links`, `profile_device_settings` (default **on** for existing managed profiles of the owner, so Phase 2 reminders keep firing), `push_state`; columns `medications.redacted` (nullable `name`), `schedules.redacted`, profile alert fields, `outbox.profile_id`. Scoped pull and the foreign-scope rules above, the self-profile fix, reminder filter (owner/guardian, not archived, device toggle on), zone rule (D4), deterministic split ids (UUID v5 of `{schedule_id}/{split_date}`, with a test against terminal tombstones).
- **Background upload of marks and one sync lease (3.7):** WorkManager (Android) / existing `beginBackgroundTask` (iOS) flushes the outbox after a notification action. **One drift lease for the whole sync (push + refresh)** across isolates, TTL longer than the HTTP timeout, with fencing (the holder checks the lease is still its own before persisting tokens or applying results). Backend: refresh is idempotent for 30 s — a repeated rotation of the same refresh token from the same device within `REFRESH_REUSE_WINDOW_SECONDS` returns the same new pair (cached in Redis under `sha256(old token)`, encrypted with a key derived from the old token) instead of revoking the family; outside the window, reuse still revokes. ADR 0001 addendum in 3.7: background network for outbox flush only, the lease, and the reuse window.
- **Screens (3.8):** Family tab ("Видят меня" with inactive grants marked, "Я вижу", "Подопечные", "new relative" banner); invite create with the disclosure list; share (QR, share sheet); accept (preview, guardian warning, explicit confirm); relative detail; managed profile form; archive banner (read-only, purge date, "Delete archive" only after `owner_erased`, "Leave"); profile switcher; relative day view (viewers read-only; editors edit `shared` medications and schedules, **no mark or delete buttons**); privacy explanations; soft-limit gating; deletion dialog; restore screen (`account_pending_deletion` → code entry → `POST /v1/auth/restore`).
- **Push (3.9):** FCM (Dart-only `FirebaseOptions` from dart-defines, no google-services plugin), RuStore (project id only), APNs native channel; registration only under the need rule above; payload parsing, local rendering, tap routing.

---

## Milestones

| # | Milestone | Scope | Done when |
|---|---|---|---|
| 3.0 | Docs and contracts | This plan, ADRs 0005–0010, decisions D1–D6, review of 2026-10-16 applied | ADRs merged |
| 3.1 | Dose-state contract | Spec, vectors, Python, Dart, app uses core | Both suites run all vectors |
| 3.2 | Backend: links, invites, permissions | Grants, invites, alert settings, well-known/landing, features flag, inventory | Endpoint matrix tests green |
| 3.3 | Backend: scoped sync and authorization | Journal by scope, `POST /v1/sync/pull`, projection, relative writes, locks | Sync privacy and convergence suites green |
| 3.3b | Backend: account deletion grace and restore | D2 request/restore (ticket + code)/erase function, D1 archive, transfer, archive purge | Deletion suite and needle test green |
| 3.4 | Backend: push infrastructure and ARQ worker | Tokens, outbox with send-time re-check, senders, worker, crons, `link_*` pushes | Delivery suite and worker wiring green |
| 3.5 | Backend: missed-dose detector | Alerts, tick, late undo, resolution, retention, schedule.md note | Detector suite green |
| 3.6 | App: scoped data layer | drift v4, scoped pull, foreign-scope rules, reminders, zones | Unit tests and host e2e green |
| 3.7 | App + backend: background upload and sync lease | WorkManager/BGTask flush, sync lease, refresh reuse window | Emulator `taken` asserts server event without app start |
| 3.8 | App: relatives UI, deep links, deletion/restore | Family tab, invites, accept, switcher, archive, delete/restore | Widget tests, APK and iOS builds green |
| 3.9 | App: push | FCM/RuStore/APNs clients, registration rule, rendering, routing | Builds green without credentials |
| 3.10 | E2E, CI, cleanup | Relatives host e2e and emulator phase, remove `GET /v1/sync/pull`, docs | All workflows green |

### 3.0 Docs and contracts
- **Files:** `docs/phase3-plan.md`, `docs/adr/0005`–`0010`, `CLAUDE.md` (current phase).
- **Reviewers:** `architect`, `privacy-compliance-reviewer`, `security-reviewer`, `offline-sync-reviewer` (done, see the review log).
- **Done when:** merged with owner sign-off.

### 3.1 Dose-state contract (spec, vectors, Python, Dart in one PR)
- **Files:** `docs/spec/dose-state.md`; `spec/dose-state-vectors/{schema,marks,snooze,missed}.json`; `spec/validate_vectors.py`; `backend/app/domain/dose_state.py` + `tests/domain/test_dose_state_vectors.py`; `packages/pillpal_core/lib/src/doses/occurrence_state.dart` (+ export) + `test/doses/dose_state_vectors_test.dart`; `app/lib/src/features/doses/dose_status.dart` and `app/lib/src/reminders/reminder_inputs.dart` delegate to core.
- **Test first:** no events; taken; skipped; taken→undo; taken→undo→taken; skipped then taken; equal `at` (larger id wins); two snoozes (latest by `at`, tie by id); snooze undone; `snooze_until` before the instant; other keys ignored; `missed` at `due + X − 1 µs` / exactly `due + X`.
- **Reviewers:** `schedule-engine-guardian`, `code-reviewer`. Risk: medium (behaviour-preserving refactor of live logic).

### 3.2 Backend: links, invites, permissions
- **Migrations:** `0004_profile_grants`, `0005_invites`, `0006_profile_alert_settings`.
- **Files:** `app/db/relatives.py`, `app/db/__init__.py`, `app/db/models.py`; `app/services/access.py` (`role_for_profile`, `accessible_profiles(user_id, roles)` — active grants); `app/domain/privacy.py`; `app/services/{invites,grants}.py`, `app/schemas/relatives.py`, `app/api/{relatives,links}.py`, `app/api/auth.py` (`GET /v1/me/features`); `app/config.py` (`invite_ttl_seconds`, `guardian_invite_ttl_seconds`, `invite_replay_window_seconds`, `max_active_invites_per_profile`, `max_access_scopes_per_user`, `public_link_base_url`, `android_*`, `apple_team_id`, `ios_bundle_id`, `feature_soft_limits`, `soft_limit_*`); `app/schemas/entities.py`, `app/services/sync.py` (keep-on-absent); `app/services/erasure.py`; `app/services/personal_data.py`; `app/main.py`; `spec/openapi.json`.
- **Endpoints:** invites create/list/delete, preview, accept; `GET /v1/grants` (outgoing with `active`, incoming); `PATCH`/`DELETE /v1/grants/{id}`; `GET /v1/me/features`; `.well-known/*`, `/i`. Foreign or missing → 404.
- **Tests first:** `test_invites.py` (happy path; expired/used/revoked; own profile; `already_linked` does not consume; guardian on self → 422; PATCH to `guardian` → 409; role change needs `disclosure_version`; guardian TTL 24 h; cap; create replay → 409; accept replay → existing grant; **accept → revoke → accept with the same token → `invite_used`**; concurrent double accept → one grant; token only hashed; `disclosure_version` copied); `test_grants.py` (matrix, mixed-field PATCH → 422, 401, 422, foreign → 404); `test_soft_limits.py`; `test_links.py` (headers, content type, no redirects, prod cert validation); `tests/domain/test_privacy_projection.py` (every field of `MedicationOut`, `ScheduleOut`, `DoseEventOut`, `ProfileOut`, `Change` classified; `ScopeOut` is deferred to 3.3); trigger tests (grantee = owner on insert and on owner change, guardian on self, tombstoned profile, `notify_missed` update allowed); inventory test; migration round-trip 0004–0006.
- **Reviewers:** `security-reviewer`, `privacy-compliance-reviewer`, `code-reviewer`. Risk: medium.

### 3.3 Backend: scoped sync and authorization
- **Migration:** `0007_sync_changes_scope` (one-step backfill only because no stand exists; the PR body says so).
- **Files:** `app/db/models.py` (`SYNC_OPS` + `privacy`); `app/services/changes.py` (`lock_journal(owner_ids)`, `record_change(profile_id, …)` with the lock assertion, `Op`); `app/services/scopes.py` (`resolve_batch_owners` via accessible profiles, `lock_for_profile`, owner re-check and retry); `app/services/entities.py`, `dose_events.py`, `auth.py` (registration journal), `erasure.py` (by scope); `app/services/sync.py` (load-then-authorize, rule order, `Rejected` codes, projected `current`); `app/services/sync_pull.py`, `sync_rows.py`, `sync_build.py`, `sync_scopes.py` (`pull_scoped`; hidden rows filtered in the SQL read so they never move a relative's cursor; LATERAL per scope; REPEATABLE READ; entity-rank order; narrowing deletes and tombstones bounded by `max(granted_seq, backfill_until)`; tombstoned-scope rule; `owner_last_seen_at`); `app/services/devices.py` (`MAX_DEVICES_PER_USER`, 409 `too_many_devices`); `app/services/scope_limit.py` (`MAX_ACCESS_SCOPES_PER_USER` also on managed-profile create); `app/limits.py` (protocol limits); `app/api/sync.py`; `app/api/resources.py` (full-access only); `app/deps.py`; `app/schemas/sync.py` (sync wire models; `ScopedPullRequest.backfill_until`, `ScopeOut.backfill_until`, `Change.scope`, redacted schemas); `backend/README.md`; `spec/openapi.json`.
- **Tests first:**
  - `test_sync_scopes.py`: new grant backfills from 0 across pages; revoked scope in `revoked`; foreign and never-existed identical; 1..50 cursors (422 beyond), limit cap, 401; changes only for requested scopes; **hidden activity does not move a relative's cursor** and pages count only readable rows; `backfill_until` is returned from cursor 0 and cleared when reached; tombstoned owned scope listed only while cursor < tombstone seq; managed-profile deletion revokes guardians' scope; `owner_last_seen_at` floored, only on foreign self scopes; `updated_by_device` null for projected roles.
  - `test_sync_privacy.py`: viewer sees shared full, anonymous redacted, hidden absent with children; shared→hidden → medication delete; hidden→shared → medication, schedules, events; shared→anonymous → redacted medication and schedules, events not re-journaled; backfill from 0 emits no hidden deletes; `test_sync_backfill.py`: multi-page backfill with `limit` below the row count, narrowing committed concurrently with accept (ordered by the journal lock, `granted_seq`), a medication created and hidden after the cursor is never a delete, no tombstones from before the grant; redacted envelopes carry no edit or deletion time; `current` of `ignored_stale` is projected.
  - `test_sync_editor.py`: shared medication upsert applied and journaled; privacy change → `forbidden_field` with projected `current`; new non-shared medication → `forbidden_field`; upsert of an existing anonymous/hidden entity → `not_found`, delete of it → `applied` (no-op), a new schedule or dose event under it → `parent_not_found` like under a missing parent (viewer and editor); upsert with the id of an existing hidden entity → `not_found` (not `integrity_error`); dose events (all types) on shared → `forbidden`; medication/schedule delete → `forbidden`; profile write → `read_only`; viewer write on shared → `forbidden`; owner/editor LWW converges.
  - `test_sync_locks.py`: foreign ids in a batch take no lock and give `not_found`; owner changed between resolve and lock → retry; `record_change` without the owner lock raises; concurrent owner and editor keep seq = commit order; multi-owner batch vs REST does not deadlock.
  - `test_access_rest.py`: guardian 200; editor and viewer 404; guardian profile delete (sync or REST) → `forbidden` for any profile; `test_devices.py`, `test_scope_limit.py`, `test_schedule_scope.py`, `test_rejournal_volume.py`.
  - All existing tests stay green, including `GET /v1/sync/pull`; migration round-trip of 0007 (privacy rows → upsert on downgrade).
- **Reviewers:** `offline-sync-reviewer`, `security-reviewer`, `privacy-compliance-reviewer`, `code-reviewer`. Risk: **high**; the PR body flags a sync protocol change and a migration.

### 3.3b Backend: account deletion grace and restore (D2, D1)
- **Migrations:** `0008_user_deletion_grace`, `0009_profile_archive`.
- **Files:** `app/db/models.py`; `app/services/account_deletion.py` (`request_deletion`, `restore_account`, `erase_expired_accounts`); `app/services/erasure.py` (D1 transfer to the earliest active co-guardian, multi-owner locks); `app/services/archives.py` (purge, retention); `app/services/auth.py` (centralized pending checks in `_issue_tokens`/`refresh`, login → `account_pending_deletion` + `restore_account` code, register mail variant, deletion and restore mails); `app/services/restore_tickets.py`; `app/deps.py` (`tokens_not_before`); `app/services/access.py` (active grants, archive roles, `active` in outgoing grants); `entities.py`, `dose_events.py`, `invites.py`, `grants.py`, `sync.py` (`read_only` on archives; guardians may only leave while `owner_pending_deletion`); `app/errors.py` (`details`); `app/observability.py` (Sentry scrub of `restore_ticket`); `app/api/auth.py` (`POST /v1/auth/restore`); `app/api/resources.py` (archive purge via `DELETE /v1/profiles/{id}` after `owner_erased`); `app/config.py`; `backend/README.md`; `infra/.env.example`; `spec/openapi.json`.
- **Tests first** (`test_account_deletion.py`, `test_account_restore.py`, `test_managed_archive.py`; fake clock):
  - delete → login with the right password gives `403 account_pending_deletion`, a ticket and a mailed code; wrong password → `401 invalid_credentials`;
  - restore with ticket + code restores data and grants; **restore without the code → 401**; ticket and code single use; expired ticket → 401;
  - deletion and restore mails are sent; the register mail carries no ticket or link;
  - relatives lose access during grace (REST 404, scope in `revoked`) and regain it on restore (backfill from 0); outgoing grants show `active: false` during grace;
  - refresh of every family fails after delete; an access token issued before delete or before restore is refused; a login racing `DELETE /me` cannot obtain a working refresh token;
  - registration during grace creates no second user; password reset works and login still offers restore;
  - open invites revoked;
  - managed profile with an active co-guardian: archived; guardian reads, writes → `read_only`, invites refused, **delete → refused, leave → allowed**; after the job it belongs to the co-guardian (`owner_erased`, `archive_purge_after` set, viewer/editor grants gone, history intact); a pending co-guardian is skipped for the transfer; without active co-guardians the profile is erased;
  - an archive already `owner_erased` (transferred to the deleting user) is not re-archived as `owner_pending_deletion`;
  - archive purge (by owner or guardian after `owner_erased`, and by retention) removes events and journal; inventory/needle covered;
  - the job erases every due user in one run (more than one batch), does nothing before `erase_after`, and `erase_after ≤ request + grace`; concurrent restore vs job → one wins;
  - migration round-trips of 0008–0009 and their CHECKs.
- **Reviewers:** `privacy-compliance-reviewer`, `security-reviewer`, `offline-sync-reviewer`, `code-reviewer`. Risk: medium-high (destructive path and auth flow).

### 3.4 Backend: push infrastructure and ARQ worker
- **Dependencies:** `arq`, `httpx[http2]` (runtime), `pyjwt[crypto]`.
- **Migrations:** `0010_push_tokens`, `0011_push_outbox`.
- **Files:** `app/db/push.py`; `app/push/{__init__,base,fcm,apns,rustore,fake,disabled,registry}.py`; `app/schemas/push.py`; `app/services/{push_tokens,push_outbox}.py`; `app/api/push.py`; `app/services/auth.py` (logout via `refresh_tokens.device_id`); `app/services/account_deletion.py` (delete tokens, drop outbox rows; `link_restored` enqueue on restore); `app/services/invites.py` (`link_accepted`); `app/worker.py` (job wrapper, JSON serializer, `keep_result=0`, crons including `erase_expired_accounts` and `cleanup_retention`); `app/config.py` (`*_FILE`, region validator); `infra/docker-compose.yml` (`worker`, Redis password), `infra/.env.example`, `CLAUDE.md` commands.
- **Tests first:**
  - `tests/push/test_{fcm,apns,rustore}_sender.py` (`httpx.MockTransport`): request shape, auth, hard-coded token URL, collapse id, error mapping, transport errors without message text.
  - `test_push_tokens.py`: format validation per provider, cap per user, reassignment, logout removal, deletion-request removal, 401, 422.
  - `test_push_outbox.py`: OK → sent; RETRY back-off; INVALID_TOKEN deletes the token; stale → dropped; concurrent claimers; disabled provider → dropped; **revoke, narrowing to hidden, archive or deletion request between enqueue and deliver → zero sends (`dropped/access_changed`)**; deletion request drops pending rows of its profiles.
  - `test_push_payload_privacy.py`: unknown keys rejected; DB CHECK; APNs body has no `m`.
  - `test_config.py`: `REGION=eu` with `RUSTORE_*` fails; `*_FILE` read.
  - `test_worker_wiring.py`: `Worker(burst=True)` runs `deliver_pushes` and `erase_expired_accounts`; JSON serializer; no results kept.
  - `test_worker_logging.py`: a failing job logs type and frames only; APNs connection error logs no token.
- **Reviewers:** `security-reviewer`, `privacy-compliance-reviewer`, `code-reviewer`. Risk: medium.

### 3.5 Backend: missed-dose detector
- **Migrations:** `0012_missed_dose_alerts`, `0013_dose_events_detector_indexes`.
- **Files:** `app/db/alerts.py`; `app/domain/missed.py`; `app/services/missed_doses.py` (tick, session lock, batch locks, candidates A/B/C, recipients, variant); `app/services/dose_events.py` (resolution, recipients recomputed); `app/worker.py`; `app/config.py` (`detector_max_window_seconds=600`, `detector_max_catchup_seconds=21600`, `detector_profile_batch=500`); `docs/spec/schedule.md` §3.1 note (D4).
- **Tests first** (`test_missed_detector.py`, fake clock, `FakePushSender`): one alert and one delivery per recipient token, nothing on the next tick; taken/skipped before due + X → nothing; early undo → alert; **late undo (after due + X) → alert in the tick that sees it**; snooze → alert at `snooze_until + X`, re-snooze moves it, late undo of a snooze; hidden → full-access recipients only; schedule created after the occurrence → nothing; grant after due → excluded; `missed_alerts_enabled=false`, `notify_missed=false`; managed owner alerted only with co-guardians, self owner never; archived, owner pending, recipient pending → nothing/excluded; **deletion request committed during a tick → no alert**; `local` uses `profiles.timezone`, `fixed` uses `fixed_tz` (Berlin gap); `unconfirmed` when devices were last seen before the instant; downtime catch-up without duplicates, > 6 h skipped and counted; two concurrent ticks → one runs; watermark never moves back; constant statements per batch; **late `taken` concurrent with a tick → either no alert or a resolved one**; invalid rule → skipped, logged with `schedule_id` and code only.
- `test_missed_resolution.py`: late `taken` resolves and sends `resolved` to recipients recomputed by rule; a second late event does nothing. Log-capture: no medication name, rule or occurrence key.
- **Reviewers:** `schedule-engine-guardian`, `offline-sync-reviewer`, `privacy-compliance-reviewer`, `code-reviewer`. Risk: high.

### 3.6 App: scoped data layer
- **Files:** `app/lib/src/data/db/{tables,database}.dart` (v4, `evictScope`, `wipeAccountData`, `outbox.profile_id`, managed-profile device setting default on); `data/api/{sync_api,sync_dto,api_exception}.dart` (scoped pull, redacted rows with nullable `name`, `details`); `data/sync/sync_engine.dart` (cursor map, groups of 50, evict missing scopes, role-change handling, stale-scope eviction); `data/sync/server_state_applier.dart` (foreign-scope rules, projected rows override pending, discard states of unknown scopes); `data/sync/outbox_pusher.dart` (**no REST reconcile for foreign scopes**: apply `current` or hard-evict on `not_found`); `data/repositories/access_repository.dart`; `features/doses/dose_providers.dart` (self = `kind == 'self'` and role `owner`); `reminders/reminder_inputs.dart` (owner/guardian, not archived, device toggle; zone rule); `data/repositories/profiles_repository.dart` (`syncDeviceZone`); `data/repositories/schedules_repository.dart` (deterministic split ids); `parseScheduleRow`.
- **Tests first:** `scoped_pull_test.dart` (cursor map, groups of 50, paging, revoked, missing scope evicted, role change per page, archived flag); `foreign_scope_applier_test.dart` (`forbidden_field` keeps the medication and applies `current`; `not_found` hard-evicts without tombstone; redacted row overrides a pending edit and drops it; states of evicted scopes discarded; hard deletes; event overwrite); `migration_v4_test.dart` (legacy cursor; managed device setting on); `reminder_inputs_scopes_test.dart` (viewer/editor/archived scopes never remind; managed `local` 08:00 Europe/Samara stays 08:00 Samara on a Berlin device; own self follows the device zone); `self_profile_test.dart`; `split_ids_test.dart` (incl. terminal tombstones); `test_e2e/scoped_sync_test.dart`.
- **Reviewers:** `offline-sync-reviewer`, `privacy-compliance-reviewer`, `notifications-specialist`, `code-reviewer`. Risk: high.

### 3.7 App + backend: background upload and sync lease
- **Files:** `app/lib/src/reminders/background_handler.dart`; `app/lib/src/data/sync/{background_flush,sync_lease}.dart` (one lease for push and refresh, fencing); `ios/Runner/AppDelegate.swift`; backend `app/services/auth.py` + `app/services/refresh_reuse.py` (30 s idempotent reuse window), `app/config.py` (`refresh_reuse_window_seconds=30`); ADR 0001 addendum.
- **Tests first:** two isolates → one push and one refresh at a time; a stale lease holder does not persist tokens; background flush keeps outbox order and never pulls; backend: repeated rotation within 30 s from the same device returns the same pair, from another device or after 30 s revokes the family; emulator `taken` phase asserts the server has the event before the app restarts.
- **Reviewers:** `notifications-specialist`, `offline-sync-reviewer`, `security-reviewer`, `code-reviewer`. Risk: high.

### 3.8 App: relatives UI, deep links, deletion and restore
- **Dependencies:** `qr_flutter`, `share_plus`, `app_links`.
- **Files:** `app/lib/src/features/family/{family_screen,family_providers,invite_create_screen,invite_share_sheet,invite_accept_screen,relative_detail_screen,managed_profile_form,profile_switcher,archived_profile_banner,new_relative_banner}.dart`; `data/api/relatives_api.dart`, `data/repositories/relatives_repository.dart`; `links/{invite_link,link_listener}.dart`; `data/config.dart`; `features/auth/{auth_flow,restore_account_screen}.dart`; `features/settings/delete_account_dialog.dart`; `routing/*`; profile-parameterized Today/Medications/History; `medication_form.dart`; `report_service.dart`; l10n RU/EN; Android manifest and Gradle placeholders; iOS entitlements and `Links.xcconfig`; `app-release.yml` merged-manifest check; owner manual checklist below.
- **Tests first:** invite link parsing (fragment, wrong host, other region, malformed); never auto-accept; guardian warning shown; widget tests per screen; redacted rows never show name or dose (Today, History, PDF); viewer and editor have no mark or delete buttons; archive banner, purge date, delete only after `owner_erased`; inactive grants shown; restore flow (ticket, code); deletion dialog content; orphan invite deleted after 409; soft limits.
- **Reviewers:** `privacy-compliance-reviewer`, `security-reviewer`, `code-reviewer`. Risk: medium.

### 3.9 App: push
- **Dependencies:** `firebase_core`, `firebase_messaging`, `flutter_rustore_push` (pinned here, ADR 0008 §7).
- **Files:** `app/lib/src/push/{push_config,push_service,fcm_client,rustore_client,apns_channel,push_payload,relatives_alert_notifier,push_background_handler}.dart`; `AppDelegate.swift`, `Runner.entitlements`; Android `settings.gradle.kts` (RuStore Maven), `build.gradle.kts` (`rustoreProjectId`), channel `VISIBILITY_PRIVATE`; `app-release.yml` (dart-defines from repo variables).
- **Tests first:** payload parsing; provider selection; **registration only under the need rule, deletion when the need ends**; notifier (local text, generic fallback, hide names, app-range id, `resolved` replaces, `unconfirmed` with the rounded last-sync hour, public version without details).
- **Reviewers:** `notifications-specialist`, `privacy-compliance-reviewer`, `security-reviewer`, `code-reviewer`. Risk: medium.

### 3.10 E2E, CI, cleanup
- **Files:** `app/test_e2e/relatives_test.dart` (incl. delete → restore of a relative's access); emulator `relatives` phase in `.github/scripts/emulator/{run.sh,host_control.py}` (invite via API, `adb am start` with the explicit package and the placeholder host, accept, privacy matrix on the day view, revoke → evicted); removal of `GET /v1/sync/pull`; `CLAUDE.md`, `backend/README.md`.
- **Manual checklist:** real FCM, APNs and RuStore receipt; app/universal links on a verified domain (after D6); iOS scenarios.
- **Reviewers:** `e2e-runner`, `code-reviewer`, `security-reviewer`. Risk: medium.

---

## Migrations and compatibility

| Revision | Milestone | Concern | Downgrade |
|---|---|---|---|
| `0004_profile_grants` | 3.2 | table, guard triggers (grants; owner change) | drop |
| `0005_invites` | 3.2 | table and trigger | drop |
| `0006_profile_alert_settings` | 3.2 | two columns with defaults | drop columns |
| `0007_sync_changes_scope` | 3.3 | journal re-keyed to `profile_id` (FK CASCADE), `privacy` op, `profile_grants.granted_seq` | restore `user_id` from owner; `privacy` rows → `upsert`; drop `granted_seq` |
| `0008_user_deletion_grace` | 3.3b | user columns, `restore_account` purpose | drop (refused while a user is pending) |
| `0009_profile_archive` | 3.3b | archive columns, guard functions | restore guard functions, drop columns (refused while archived) |
| `0010_push_tokens` / `0011_push_outbox` | 3.4 | tables | drop |
| `0012_missed_dose_alerts` | 3.5 | alerts, `detector_state` | drop |
| `0013_dose_events_detector_indexes` | 3.5 | two partial indexes | drop indexes |

- Revision ids are at most 32 characters (`alembic_version.version_num` is VARCHAR(32)): 3.2 shipped `0006_profile_alert_settings`; `0013_dose_events_detector_indexes` (33) must be shortened when 3.5 lands.
- No revision rewrites `dose_events`. `0007` backfills in one step only because no stand exists.
- Schedule rule `v`, engine spec and schedule vectors unchanged, apart from the §3.1 note (3.5).
- **Sync protocol:** `POST /v1/sync/pull` (3.3), `GET` removed (3.10); `Change.scope`; `ScopeOut` (with `backfill_until`) and the optional request field `backfill_until`; redacted schemas (anonymous envelopes have null `client_updated_at` and, on tombstones, `deleted_at`); deletes of invisible entities answer `applied`; 409 `too_many_devices`; rejection codes `not_found`, `forbidden`, `read_only`, `forbidden_field` with projected `current`.
- **Auth API:** `DELETE /v1/me` (204) no longer erases at once; login may return `403 account_pending_deletion` with `details`; `POST /v1/auth/restore`; refresh reuse window (3.7).

## Privacy and region impact

- New personal data: grants (with `disclosure_version`), invites, push tokens, alerts (medical), last-sync hour (D5). All in the erasure path and the inventory; retention as listed above.
- **D2:** relatives, detection and push stop at the request (enforced at enqueue and at send); data is kept blocked ≤ 30 days only to allow restore, then erased.
- **D1:** the managed person's data stays with active co-guardians for `MANAGED_ARCHIVE_RETENTION_DAYS`, then is purged; device ids on retained rows are cleared at transfer.
- Projection in one pure module for pull, push results and PDF; REST closed to relatives; ids-only payloads; worker and sender logs carry type, frames, ids and codes only.
- Third parties: FCM and APNs in both regions, RuStore in RU only (startup fails otherwise). See ADR 0008 §8.
- Regions: one regional DB, no shared queue; other-region link hosts refused.

## Legal review required before launch

Not code defects; to be confirmed by counsel before production (Phase 5 legal documents):
1. 152-FZ art. 21(5) / GDPR art. 17: is 30 days of **blocked** storage after a deletion request (consent withdrawal) acceptable for the sole purpose of restore, and must the user be notified of destruction?
2. Whether an **"erase immediately, no restore"** option must be offered alongside D2 (not built: D2 is archive-with-restore).
3. RKN notification of **cross-border transfer** (152-FZ art. 12) for FCM and APNs tokens from the RU region.
4. Health-related **push metadata** visible to Google, Apple and VK (a `missed` push at a given time for a recipient): acceptable pseudonymous metadata, or end-to-end encrypt payloads?
5. **Legal basis for managed profiles** (child: legal representative; adult: own consent or guardianship; pet: not personal data), for the D1 archive transfer, and for keeping the deleted owner's notes in the archive.
6. Disclosure of the owner's **last sync time** (D5) to relatives as personal data; adequacy of the invite disclosure screen and `disclosure_version` as the consent record.

## Reviewers to run (agents)
`architect` (3.0); `schedule-engine-guardian` (3.1, 3.5); `offline-sync-reviewer` (3.3, 3.3b, 3.5, 3.6, 3.7); `privacy-compliance-reviewer` (3.0, 3.2–3.6, 3.8, 3.9); `security-reviewer` (3.2–3.4, 3.7–3.10); `notifications-specialist` (3.6, 3.7, 3.9); `e2e-runner` (3.10); `code-reviewer` and `doc-updater` on every PR.

## Done when (phase)
- [ ] `/verify` green (ruff, format, mypy strict, pytest ≥ 85% on real PG and Redis; Dart format, analyze, test in CI).
- [ ] Vectors parity for `schedule-vectors` and `dose-state-vectors`.
- [ ] `app.yml` (incl. host e2e), `app-emulator.yml` (incl. `relatives`), `app-release.yml`, `app-ios.yml` green without push credentials.
- [ ] `alembic upgrade head` / `downgrade -1` round-trip for 0004–0013; `spec/openapi.json` refreshed.
- [ ] Manual checklist done once credentials and a domain exist (not blocking merge); legal review items answered before launch.

## Out of scope / follow-ups
- iOS Notification Service Extension; silent "sync now" pushes to co-guardians; detector sharding; local nicknames; "request access"; un-archiving after `owner_erased`; per-scope full resync (only if journal compaction appears); Phase 2 leftovers (iOS widget, iOS backup exclusion, SQLCipher); Phase 4/5 work.

## ADRs
- **0005** roles, matrix (D3), guardianship and the D1 archive, invites, soft limits.
- **0006** journal by scope, locks, scoped pull, projection, relative writes, client rules.
- **0007** detector windows, locks, late undo, offline policy (D5), zones (D4), worker.
- **0008** providers, payload, send-time re-check, tokens, logging, third parties.
- **0009** invite URL, link host (D6), verification, lifecycle.
- **0010** D2 deletion, restore, erasure, interplay with D1, legal rationale.
- **ADR 0001 addendum** (3.7): background outbox flush, single sync lease with fencing, refresh reuse window.

---

## Owner decisions (2026-10-16)

| # | Topic | Decision | Where it lands |
|---|---|---|---|
| D1 | Managed profile when its owner's account goes away | **Read-only archive** for co-guardians: reminders and alerts stop, no edits, no invites; history readable. While the owner can still restore, guardians may only leave; after the owner's erasure ownership moves to the earliest active co-guardian, any guardian may delete (purge) it, and it is purged after `MANAGED_ARCHIVE_RETENTION_DAYS` (365). Without active co-guardians it is erased with the owner. | ADR 0005 §5, ADR 0010; 3.3b, 3.5, 3.6, 3.8 |
| D2 | Account deletion | **Archive with restore** (supersedes Phase 1's immediate erase): `pending_deletion`, tokens revoked, profiles hidden from relatives, detection off, managed profiles archived. Restore = password + restore ticket + e-mail code. Registration during grace creates no duplicate. After **30 days** (`ACCOUNT_DELETION_GRACE_DAYS`) an hourly job erases. | ADR 0010; 3.3b, 3.4, 3.8 |
| D3 | Does `view+edit` include marking doses? | **No.** Editors create and update `shared` medications and schedules only; dose events and deletes from editors → `forbidden`. | ADR 0005 §2, ADR 0006 §6; 3.3, 3.8 |
| D4 | Zone of `local` medications on other people's devices | **The profile's zone** for every scope except the user's own self profile, which follows the device. | ADR 0007 §5; 3.5, 3.6 |
| D5 | `unconfirmed` alert variant | **Yes**; the last sync hour is exposed in `ScopeOut`, never in pushes. | ADR 0007 §4; 3.3, 3.5, 3.9 |
| D6 | Invite link domain | **Not decided**; placeholder `*.pillpal.invalid`; non-blocking. | ADR 0009; 3.2, 3.8, 3.10 |
| — | Fixed by the TZ | Default threshold 30 min (5–720); RuStore Push included. | ADR 0007, ADR 0008 |

## Review log (2026-10-16)

Security, privacy, offline-sync and architect reviews of PR #12 applied (all blockers and should-fix items; nits except where noted):
- **Order:** 3.3 scoped sync now precedes deletion grace, renamed **3.3b**; migrations renumbered (`0007_sync_changes_scope`, `0008_user_deletion_grace`, `0009_profile_archive`, `0010`–`0013`); push-token parts of deletion moved to 3.4.
- **Sync:** read-based per-scope cursors; changes only for requested scopes, groups of 50, scope cap; tombstoned-scope rule; REPEATABLE READ pages, entity-rank order, no hidden deletes at cursor 0; events re-journaled only on hidden ↔ visible; load-then-authorize, explicit `Rejected` codes, rule order for editors (no deletes, no dose events), projected `current`; foreign-scope client rules (no REST, apply `current`, hard-evict on `not_found`, projected rows override pending, evict missing/stale scopes, role change per page, `outbox.profile_id`); owner resolution via accessible profiles, re-check after lock, lock assertion in `record_change`; `updated_by_device` hidden from projected roles.
- **Detector:** session advisory lock per tick, per-batch journal locks, watermark last; candidates C (late undo); recipients of `resolved` recomputed; snooze tie rule; `owner_last_seen_at` for D5 text.
- **Push:** send-time access re-check; deletion request drops pending rows; worker logging policy, JSON serializer, `keep_result=0`, Redis auth; token format checks, cap, need-based registration; EU without RuStore enforced; per-region credentials, `*_FILE`, fixed OAuth URL; APNs without `m`, neutral keys; private Android channel.
- **Deletion/restore:** e-mail code for restore, deletion and restore mails, centralized pending checks, `tokens_not_before`, user row lock, Sentry scrub, `link_restored` and inactive grants visible to owners; guardians may only leave while the owner is pending; transfer to the earliest active co-guardian; archive retention and purge; job loops with `erasure_overdue_count`. An "erase immediately" option was **not** added (D2); it is listed under legal review.
- **Invites:** replay never re-creates a grant; `already_linked` does not consume; guardian TTL 24 h with warning and a push-independent banner; no custom scheme in any build; orphan invite deleted after 409; `disclosure_version`; consumed-by nulled after 24 h.
- **Other:** refresh reuse window (30 s) and single sync lease (3.7); retention tightened (alerts 72 h, sent outbox 24 h); zone rule for all foreign scopes; managed device setting defaults on; guard triggers limited to insert/role change; logout device from the refresh token; legal review section.
