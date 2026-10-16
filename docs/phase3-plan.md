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
- No Phase 4/5 work: no catalog, no OAuth, no data export endpoint, no legal consent records, no regional client routing.

Each milestone is one PR into `main`, merged only with green CI. Phase 2 is merged, so backend (3.1–3.5)
and app (3.6+) milestones are not blocked by it; app milestones that change `app-emulator.yml` or
`.github/scripts/emulator/` go one at a time to avoid conflicts on those files.

## Requirements (restated)

- **Symmetric links.** Every person has their own account. A profile owner grants another account `view` or `view+edit` on one profile, by invite link or QR. The invitee confirms. Links never cross regions.
- **Managed profiles** (grandma without a smartphone, child, pet) are run by guardian accounts. Reminders fire on guardians' devices. A profile can have more than one guardian.
- **Per-medication privacy** (`shared` / `anonymous` / `hidden`) is enforced server-side on every relative-facing path: API, sync pull, missed-dose push, shared PDF. `anonymous` exposes time and status only.
- **Server-side missed-dose detector** (ARQ). When an occurrence is still unmarked X minutes after it is due (default 30, configurable), relatives get a push. That means one push per occurrence per recipient, and no medical data in the payload.
- **Push** via FCM, APNs, and RuStore Push (for devices without GMS).
- **Soft limits** (≈3 relatives, number of PDF reports) live behind a feature flag that stays off.
- **Account deletion with a grace period** (D2): deletion first archives the account for 30 days with restore, then erases it.

## Assumptions

- No installation or deployment exists outside dev and CI: there is no CD, and ADR 0002 says "no installation exists yet". So protocol changes need no long deprecation window. Alembic revisions must still be reversible, and journal backfills are allowed in one step (they would be split if a stand existed).
- "Relative" means anyone holding a grant on a profile. Guardians of a managed profile have full access, including `hidden` medications: privacy protects the profile from relatives, not from the people who run it.
- Grants, invites, alerts and push-outbox rows get **server-generated ids**. That is deliberate: none of them can be created offline. Invites take a client UUID so a lost create response can be retried safely. Medications, schedules and dose events keep client UUIDs as before.
- `docs/TZ.md` and `README.md` are not edited.

## Key decisions (fixed in ADRs 0005–0010)

1. **Roles** (ADR 0005).
   - `owner` is `profiles.owner_user_id`. For a managed profile the owner is its primary guardian.
   - `guardian` exists on managed profiles only.
   - `editor` is "view+edit"; `viewer` is "view".
   - Full-access roles are `owner` and `guardian`. Projected roles are `editor` and `viewer`.
   - **Editors edit `shared` medications and schedules only; they never record dose events** (D3).
2. **The sync journal is keyed by profile (scope), not by user** (ADR 0006). Pull takes one cursor per scope. The journal lock key stays the **owner user id of the scope**, so every scope of one owner is serialized by the same advisory lock as today. A per-scope cursor is safe because each scope's cursor only advances to that scope's own last returned `seq`.
3. **The privacy projection is a pure domain function**, applied at pull time for projected roles. Privacy changes re-journal the medication's children so redacted or full versions replace what relatives already hold. A narrowing to `hidden` evicts the medication from relatives' devices.
4. **REST CRUD stays limited to full-access roles.** Relatives (`viewer`, `editor`) read and write only through sync, so the projected surface is one code path.
5. **The detector is stateless and windowed** (ADR 0007). A watermark in PostgreSQL defines each tick's half-open window. Every occurrence is evaluated exactly once, at its final due time + X. A UNIQUE alert row gives idempotency.
6. **Push payloads carry ids only** (ADR 0008): `type`, `alert_id`, `profile_id`, `medication_id` (all opaque). Visible text is rendered on the device from local, already-projected data, or is a generic localized key.
7. **Invite links** (ADR 0009): `https://{link_host}/i#<token>`. The token sits in the URL fragment, so it never reaches the server or proxy logs. `link_host` is per region and config-driven, with the placeholder `*.pillpal.invalid` until the owner picks a domain (D6).
8. **Account deletion is an archive with restore** (ADR 0010, D2): `DELETE /v1/me` sets the account to `pending_deletion` for `ACCOUNT_DELETION_GRACE_DAYS` (30); signing in again offers "Restore account"; after the grace period an ARQ job hard-erases.
9. **A managed profile whose owner goes away becomes a read-only archive for its co-guardians** (ADR 0005 §5, D1): no reminders, no missed-dose alerts, no edits, no invites; history stays readable; any co-guardian may delete it. With no co-guardians it is erased with the owner's data.

---

## Data model

### New tables

New ORM modules (`models.py` would exceed 400 lines) are `backend/app/db/relatives.py`, `backend/app/db/push.py` and `backend/app/db/alerts.py`. `app/db/__init__.py` imports them so Alembic's `env.py` sees the metadata.

**`profile_grants`** (revision `0004_profile_grants`)

| Column | Type | Constraint |
|---|---|---|
| `id` | uuid | PK (server-generated) |
| `profile_id` | uuid | FK `profiles.id` ON DELETE CASCADE |
| `grantee_user_id` | uuid | FK `users.id` ON DELETE CASCADE |
| `role` | text | CHECK `role IN ('viewer','editor','guardian')` |
| `notify_missed` | bool | NOT NULL DEFAULT true (grantee's choice) |
| `invite_id` | uuid null | provenance only, no FK (invites are purged) |
| `created_at`, `updated_at` | timestamptz | NOT NULL DEFAULT now() |

- UNIQUE `(profile_id, grantee_user_id)`; index `(grantee_user_id)`; index `(profile_id, role, created_at)` (earliest co-guardian lookup, D1).
- Trigger `profile_grants_guard` (BEFORE INSERT/UPDATE) rejects `grantee_user_id = profiles.owner_user_id`, `role = 'guardian'` on a non-managed profile, and grants on a tombstoned profile. Revision `0008_profile_archive` extends it to reject new grants on an archived profile. These invariants live in the DB, not only in code.
- Revocation is a hard DELETE. No history of who was linked is kept (minimization). Devices learn about it from the scope list on their next pull.
- A grant is **active** only while both its grantee and the profile's owner are not `pending_deletion` (D2). Inactive grants are kept (so restore brings them back) but give no access and no alerts; this is part of the access predicate, not a stored flag.

**`invites`** (revision `0005_invites`)

| Column | Type | Constraint |
|---|---|---|
| `id` | uuid | PK, client UUID (idempotent create) |
| `profile_id` | uuid | FK `profiles.id` ON DELETE CASCADE |
| `created_by_user_id` | uuid | FK `users.id` ON DELETE CASCADE |
| `role` | text | CHECK in (`viewer`,`editor`,`guardian`) |
| `token_hash` | text | UNIQUE, `sha256(token)` hex. The token is 256 bits from `secrets.token_urlsafe(32)`, so no slow hash is needed. |
| `created_at` | timestamptz | NOT NULL DEFAULT now() |
| `expires_at` | timestamptz | NOT NULL, CHECK `expires_at > created_at` |
| `consumed_at` | timestamptz null | single use |
| `consumed_by_user_id` | uuid null | FK `users.id` ON DELETE SET NULL |
| `revoked_at` | timestamptz null | |

- CHECK `NOT (consumed_at IS NOT NULL AND revoked_at IS NOT NULL)`.
- Partial index `(profile_id) WHERE consumed_at IS NULL AND revoked_at IS NULL` for the active-invites cap.
- The guardian-only-on-managed rule is enforced by a trigger, as for grants; `0008_profile_archive` adds "no invite on an archived profile".
- Retention: the cleanup cron deletes invites expired, consumed or revoked more than 30 days ago.

**`push_tokens`** (revision `0010_push_tokens`)

| Column | Type | Constraint |
|---|---|---|
| `id` | uuid | PK (server) |
| `user_id`, `device_id` | uuid, text | FK `(user_id, device_id)` → `devices(user_id, device_id)` ON DELETE CASCADE; UNIQUE `(user_id, device_id)` (one token per installation) |
| `provider` | text | CHECK in (`fcm`,`apns`,`rustore`) |
| `token` | text | CHECK `char_length BETWEEN 1 AND 4096`; UNIQUE `(provider, token)`. A token that moves to another account is reassigned (the old row is deleted in the same transaction). |
| `apns_environment` | text null | CHECK `(provider = 'apns') = (apns_environment IS NOT NULL)`, values `sandbox`/`production` |
| `created_at`, `updated_at`, `last_success_at` | timestamptz | |

**`push_outbox`** (revision `0011_push_outbox`): a transactional outbox, at-least-once.

| Column | Type | Constraint |
|---|---|---|
| `id` | bigserial | PK |
| `push_token_id` | uuid | FK `push_tokens.id` ON DELETE CASCADE |
| `recipient_user_id` | uuid | FK `users.id` ON DELETE CASCADE |
| `subject_profile_id` | uuid null | FK `profiles.id` ON DELETE CASCADE (erasure follows the subject) |
| `kind` | text | CHECK in (`missed`,`resolved`,`link_accepted`) |
| `dedupe_key` | text | UNIQUE (e.g. `missed:{alert_id}:{push_token_id}`) |
| `payload` | jsonb | built only from `PushPayload` (strict Pydantic, ids and enums only); CHECK that the keys are a subset of `{v,t,a,p,m,g,s}` |
| `status` | text | CHECK in (`pending`,`sent`,`dropped`) |
| `attempts` | int | CHECK `>= 0` |
| `next_attempt_at`, `created_at`, `sent_at` | timestamptz | |
| `last_error_code` | text null | provider error code only, never a token |

Index `(next_attempt_at) WHERE status = 'pending'`. Retention: 7 days.

**`missed_dose_alerts`** (revision `0012_missed_dose_alerts`)

| Column | Type | Constraint |
|---|---|---|
| `id` | uuid | PK (server) |
| `profile_id` | uuid | FK `profiles.id` ON DELETE CASCADE |
| `medication_id` | uuid | FK `medications.id` ON DELETE CASCADE |
| `occurrence_key` | text | CHECK `char_length <= 64` |
| `due_at` | timestamptz | final due instant (§ detector) |
| `variant` | text | CHECK in (`missed`,`unconfirmed`) |
| `detected_at` | timestamptz | |
| `resolved_at` | timestamptz null | set when a late `taken`/`skipped` arrives |

UNIQUE `(profile_id, occurrence_key)`: the "one alert per occurrence" guarantee. Retention: 30 days. The revision also creates **`detector_state`** (`name text PK`, `watermark timestamptz NOT NULL`), seeded with `('missed_dose', now())`.

### Changed tables

| Table | Change | Revision |
|---|---|---|
| `profiles` | Adds `missed_alert_minutes int NOT NULL DEFAULT 30 CHECK (BETWEEN 5 AND 720)` and `missed_alerts_enabled bool NOT NULL DEFAULT true`. Metadata-only `ADD COLUMN` with defaults on PG 16; synced fields. | `0006_profile_missed_alert_settings` |
| `users` | Adds `deletion_requested_at timestamptz null` and `erase_after timestamptz null`; CHECK `(deletion_requested_at IS NULL) = (erase_after IS NULL)`, CHECK `erase_after > deletion_requested_at`; partial index `(erase_after) WHERE erase_after IS NOT NULL` for the erasure job. `pending_deletion` ⇔ `deletion_requested_at IS NOT NULL` (D2). | `0007_user_deletion_grace` |
| `profiles` | Adds `archived_at timestamptz null` and `archive_reason text null CHECK IN ('owner_pending_deletion','owner_erased')`; CHECK `(archived_at IS NULL) = (archive_reason IS NULL)`; CHECK `archived_at IS NULL OR kind = 'managed'`. Replaces the grant and invite guard functions to refuse archived profiles. Server-controlled, never read from input (D1). | `0008_profile_archive` |
| `sync_changes` | Adds `profile_id uuid NOT NULL` (scope) and index `(profile_id, seq)`; backfills from entity → profile; drops `user_id` and `ix_sync_changes_user_id_seq`. The downgrade restores `user_id` from `profiles.owner_user_id`. CHECK `op IN ('upsert','delete','privacy')`. The new `privacy` op exists only in the journal and never goes on the wire. | `0009_sync_changes_scope` |
| `dose_events` | Adds partial index `ix_dose_events_snooze_until (snooze_until) WHERE type = 'snoozed'` for the detector. No column change; the append-only trigger is untouched. | `0013_dose_events_snooze_index` |
| `medications.privacy` | Unchanged column, now enforced on relative paths. Default stays `shared` (ADR 0003 §7). The grant screen shows what the relative will see. | — |
| managed profiles | No new table. `owner_user_id` is the primary guardian; co-guardians are `profile_grants.role = 'guardian'`. | — |

### Deletion and export coverage (privacy.md rule 7)

Account deletion has two stages (ADR 0010):

- **Request (`DELETE /v1/me`, D2)**, one transaction under the journal lock of the user:
  - set `deletion_requested_at = now`, `erase_after = now + ACCOUNT_DELETION_GRACE_DAYS − ACCOUNT_ERASURE_JOB_INTERVAL` (so the hard erase finishes within the grace period, ADR 0010 §4);
  - revoke every refresh-token family of the user; delete the user's `push_tokens` (cascading their pending `push_outbox` rows);
  - revoke the user's open invites (`revoked_at = now`);
  - owned managed profiles: set `archived_at = now`, `archive_reason = 'owner_pending_deletion'` (D1);
  - nothing is erased yet. Grants stay but are inactive (access predicate); the detector skips the user's profiles; access JWTs of the user are refused by `get_current_user`.
- **Restore (`POST /v1/auth/restore`)** clears the two user columns and un-archives the profiles archived with `owner_pending_deletion`. Grants become active again. Nothing else needs restoring: no data was removed.
- **Hard erase** (`erase_account`, `backend/app/services/erasure.py`, called by the hourly ARQ job `erase_expired_accounts` once `erase_after ≤ now`) also deletes, in the same transaction and FK order:
  - **D1 transfer first:** for each owned managed profile with at least one `guardian` grant, `owner_user_id` becomes the earliest co-guardian (`ORDER BY created_at, id`), that guardian's grant is deleted, the profile's `viewer`/`editor` grants are deleted, and `archive_reason` becomes `owner_erased`. The journal locks of the old and new owners are taken in sorted order. These profiles and their medications, schedules, dose events, journal rows and alerts are kept;
  - `push_outbox` rows where `recipient_user_id = user` or the subject profile is still owned;
  - `push_tokens` of the user;
  - `missed_dose_alerts` of still-owned profiles;
  - `profile_grants` where `grantee_user_id = user` or the profile is still owned;
  - `invites` created by the user or on still-owned profiles (`consumed_by_user_id` is set to NULL elsewhere);
  - `sync_changes` of still-owned profile scopes, replacing the old `user_id` delete;
  - then the existing statements (dose events, schedules, medications, profiles, devices, refresh tokens, e-mail codes, user).
- **Inventory guard (new):** `backend/app/services/personal_data.py` declares `TABLE_CLASSIFICATION: dict[str, Literal["personal", "medical", "system"]]`. A test fails if any table in `Base.metadata` is unclassified. The existing needle test `test_account_deletion_erases_all_owned_rows` drives the full path (request, then the job after the grace period) and is extended with grant, invite, token, alert and outbox ids. Phase 5's export endpoint will consume the same inventory.
- App: `AppDatabase.wipeAccountData` covers the new drift tables (`access_scopes`, `relative_links`, `profile_device_settings`, `push_state`). The deleting device wipes local data at once; a restore re-pulls from the server.

---

## Access model and privacy projection

| Capability | owner (self) | owner (managed) | guardian | editor | viewer |
|---|---|---|---|---|---|
| Read profile (name, zone) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Read alert settings | ✓ | ✓ | ✓ | — | — |
| `shared` medications | full | full | full | full | full |
| `anonymous` medications | full | full | full | redacted | redacted |
| `hidden` medications | full | full | full | — | — |
| Write meds/schedules | all | all | all | `shared` only; `privacy` immutable; new meds `shared` | — |
| Record dose events (taken/skipped/snoozed/undo) | all | all | all | — (**D3**: `rejected/forbidden`) | — |
| Edit profile, alert settings, privacy | ✓ | ✓ | ✓ | — | — |
| Invites and grants management | ✓ | ✓ | — | — | — |
| Delete profile | — (self protected) | ✓ | — | — | — |
| Local reminders | ✓ | ✓ | ✓ (per-device toggle) | — | — |
| Missed-dose push | — (has local reminders) | ✓ | ✓ | ✓ (opt-out) | ✓ (opt-out) |
| Leave (delete own grant) | — | — | ✓ | ✓ | ✓ |

**Archived managed profile (D1)** overrides the matrix for everyone, including the (transferred) owner:

| Capability | Archived profile |
|---|---|
| Read profile, medications, schedules, dose events (Today, History, PDF) | owner and guardians: full; viewers and editors: none while the archive reason is `owner_pending_deletion` (their grants are inactive), and their grants are deleted at `owner_erased` |
| Any write (profile, medications, schedules, dose events, alert settings) | rejected: REST `409 read_only`, sync `rejected/read_only` |
| Invites, new grants, role changes | refused (`409 read_only`; DB guard triggers) |
| Local reminders | none on any device |
| Missed-dose detection | skipped |
| Delete the archive (tombstone the profile) | owner or any guardian |
| Leave | guardians |

**Pending-deletion account (D2):** while `pending_deletion`, its self profile and non-archived owned profiles are invisible to relatives (grants inactive), its own grants on other profiles are inactive, it receives no pushes, and its profiles are not monitored. On restore everything is active again.

**Redacted shapes** (`backend/app/domain/privacy.py`, pure, ~100% covered):

- **Medication, `anonymous`:** `{id, profile_id, privacy, tz_mode, fixed_tz, redacted: true}`. No `name`, `form`, `strength_text`, `notes` or stock fields.
- **Schedule of an `anonymous` medication:** `{id, medication_id, redacted: true, rule: {v, kind, start_date, end_date, weekdays?, interval_days?, times: [{"time": "HH:MM"}]}}`. Doses are removed: the dose amount is not part of "time and status".
- **Dose event, projected roles:** `note` and `device_id` are always removed. `type`, `at`, `occurrence_key`, `target_event_id`, `snooze_until` and `recorded_at` stay.
- **Profile, projected roles:** `{id, kind, display_name, timezone}`.
- **`hidden`, projected roles:** the medication and its children are never returned. On a privacy narrowing the medication is emitted as `delete` (eviction), see below.

The app parses a redacted rule by injecting a placeholder dose before `ScheduleRule.fromJson`, in one helper (`parseScheduleRow`). The UI never renders doses of redacted schedules, and a widget test proves it. Engine, spec and vectors are unchanged.

---

## Sync protocol changes (milestone 3.3)

**Journal.** `record_change(session, profile_id, entity, entity_id, op)`. Every write journals into the scope of the affected profile:
- REST and push writes by owners, guardians and editors;
- cascaded tombstones;
- re-journaled children after a privacy change.

`lock_journal(session, owner_user_ids)` takes `pg_advisory_xact_lock` for each owner id in sorted order. Push resolves the owners of all scopes touched by the batch before applying it (`app/services/scopes.py: resolve_batch_owners`): from ids, from payload `profile_id`/`medication_id`, and from in-batch parents. Mutations that cannot be resolved are rejected later as `parent_not_found`, as today. REST writes lock the owner of the path's profile (helper `lock_for_profile`, which replaces the `JournalLock` dependency for profile-addressed writes). The D1 ownership transfer takes the locks of both owners, so it is serialized against writers of either.

**Scoped pull: `POST /v1/sync/pull`** (requires `X-Device-ID`; touches `devices.last_seen_at`, at most one write per 5 min).

```jsonc
// request
{"cursors": {"<profile_id>": 123, "...": 0}, "limit": 200}   // ≤ 50 cursors, limit ≤ 500 (server cap)
// response
{
  "scopes":  [{"profile_id": "…", "role": "owner|guardian|editor|viewer", "kind": "self|managed",
               "archived": false, "cursor": 456}],
  "revoked": ["<profile_id>"],          // requested scopes the caller cannot access (never existed == revoked: no oracle)
  "changes": [{"seq": 455, "scope": "<profile_id>", "entity": "medication", "id": "…", "op": "upsert|delete",
               "data": {…} | null, "client_updated_at": …, "updated_by_device": …, "deleted_at": …}],
  "has_more": false
}
```

- `scopes` lists every accessible scope: owned profiles (tombstoned ones too, so deletes propagate) plus profiles behind active grants. A scope missing from `cursors` starts at 0, which is how a new grant (or a restored account's grant) gets its backfill.
- `archived: true` marks a D1 archive: the client stops reminders for it, shows it read-only, and does not queue writes.
- One query reads `sync_changes JOIN (VALUES (scope, cursor)…) WHERE seq > cursor ORDER BY seq LIMIT limit+1`. The existing collapse per entity (first position, latest seq) is kept per scope. Each scope's returned `cursor` is the max seq returned for that scope, or unchanged.
- Projected roles get the projection: entities of `hidden` medications are skipped. A `delete`/`privacy` journal row of a medication that is now hidden is emitted as `op: delete, data: null`, with conflict-key fields set to null.
- **Privacy change.** The medication is journaled with op `privacy`, and all its schedules and dose events are re-journaled (`record_changes`, bounded by the medication's history). Relatives then overwrite their copies (redacted or full) or, for `hidden`, evict the medication with its children.
- **Grant revoked, grant inactive (D2) or profile deleted.** The scope disappears from `scopes`; if the client sent its cursor, it appears in `revoked`. The client deletes the scope's profile, medications, schedules, dose events and outbox entries in one transaction. Server-side access ends at once. **Known limitation:** a device that never syncs keeps its copy until its next pull, because remote wipe is impossible.
- **Role change.** The client evicts the scope and re-pulls it from 0. The server does nothing special: the role in `scopes` changed. The D1 transfer is a role change for the new owner (`guardian` → `owner`).
- **Client rules for foreign scopes** (projected roles): deletes are hard deletes, never tombstones; dose events are overwritten, not insert-if-missing (notes get stripped). Push results `rejected/not_found`, `read_only` or `forbidden` park the outbox entry.
- **Editor push.**
  - Medication upserts must keep `privacy` (`rejected/forbidden_field`), and new medications must be `shared`.
  - Writes to `anonymous` or `hidden` medications are `rejected/not_found`.
  - **Dose events from an editor are `rejected/forbidden`** on any medication the editor can see (D3); on a hidden or unknown one they are `rejected/not_found`.
  - Profile upserts and deletes are `rejected/read_only`.
  - Viewer writes are `rejected/not_found`.
- **Archived scope push** (D1): every write is `rejected/read_only`, except a profile `delete` by the owner or a guardian.
- **Compatibility.** `GET /v1/sync/pull` (owner scopes, one cursor) stays until the app switches in 3.6. It is safe because all of one owner's scopes share the owner lock. It is removed in 3.10. `Change` gains a `scope` field. `ProfileData` gains optional `missed_alert_minutes` / `missed_alerts_enabled`; an absent field keeps the stored value, so the existing app's full-state profile pushes do not reset them.
- **Migration of the client cursor.** On drift v4, the old global `pullCursor` becomes the cursor of every local profile, all of which are owned before 3.6. This is valid because `seq` is global.

---

## Missed-dose detector (milestone 3.5)

**Shared semantics first (milestone 3.1).** `docs/spec/dose-state.md` defines the state of an occurrence from its dose events, which today exists only in Dart in the app (`effectiveMark`, `occurrenceStates`):
- the effective mark (ADR 0003 §6: last non-undone `taken`/`skipped` by `at`, tie on the larger id);
- the latest non-undone snooze;
- `due = max(occurrence instant, latest snooze_until)`;
- `missed(T, X) ⇔ no mark ∧ T ≥ due + X`.

These semantics become vectors in `spec/dose-state-vectors/`, a Python reference (`backend/app/domain/dose_state.py`) and a Dart port in `pillpal_core`. Both run every vector.

**Trigger.** An ARQ cron `detect_missed_doses` runs every 60 s (`second={0}`, `unique=True`).

**Tick (one transaction per profile batch, watermark last):**
1. `SELECT watermark FROM detector_state WHERE name='missed_dose' FOR UPDATE NOWAIT`. If the row is locked, another worker is ticking, so skip. Window `[w, e)` with `e = min(now, w + detector_max_window)` (10 min). If `now − w > detector_max_catchup` (6 h), jump `w` to `now − max_catchup` and log `detector_gap_skipped` with a count only.
2. Load eligible profiles, keyset-paged by id with `detector_profile_batch` (500): live, **not archived** (D1), owner **not `pending_deletion`** (D2), `missed_alerts_enabled`, and either `kind = 'managed'` or with ≥ 1 active grant having `notify_missed`.
3. Per profile with `X = missed_alert_minutes`:
   - **Candidates A:** for every live schedule of a live, non-archived medication (rule validated by `ScheduleRule`; `as_needed` yields nothing), `expand(rule, schedule_id, tz, start = w − X, end = e − X)`. Here `tz = fixed_tz` if `tz_mode = fixed`, else `profiles.timezone`. Drop occurrences with `at_utc < schedules.created_at`: a schedule created after its own dose time does not alarm.
   - **Candidates B:** keys of non-undone `snoozed` events with `snooze_until + X ∈ [w, e)` (partial index from `0013`).
   - Load all events for `(profile_id, occurrence_key IN candidates)` (existing index). Evaluate `dose_state`. Keep keys with no mark and `due + X ∈ [w, e)`. That window test on the *final* due makes every occurrence counted exactly once. A snoozed one is only counted at `snooze_until + X`, and a re-snooze moves it again.
4. `INSERT … ON CONFLICT (profile_id, occurrence_key) DO NOTHING RETURNING id`. For new alerts, pick recipients:
   - the owner of a managed profile;
   - grantees of active grants with `notify_missed` and `grant.created_at ≤ due` (no backlog flood after a new link);
   - **for `hidden` medications only full-access recipients** (managed owner, guardians);
   - never a recipient in `pending_deletion` (they have no push tokens anyway).
   - Insert one `push_outbox` row per recipient token (`dedupe_key = missed:{alert}:{token}`).
5. Set `watermark = e`, commit, `enqueue_job('deliver_pushes')`. The delivery cron also polls every 10 s, so a lost enqueue only adds latency.

**Offline policy (no silent suppression, no false certainty):**
- The detector decides at `due + X` on what the server knows. It never waits for devices, because "phone off" is exactly when relatives need to know.
- **`unconfirmed` variant (D5).** For a `self` profile, if every device of the owner was last seen (`devices.last_seen_at`, touched by push, refresh and scoped pull) before the occurrence instant, the alert is `variant = unconfirmed`. The text reads "no confirmation, phone not synced since …"; otherwise it reads "dose not marked". Managed profiles are always `missed`.
- When a `taken`/`skipped` for an alerted occurrence is recorded later (sync push or REST, in `record_dose_event`, same transaction), the alert gets `resolved_at` and `resolved` pushes go to the recipients of the `missed` push. They reuse the alert's notification tag, so the alarm is replaced on the device. An alert is never re-sent.
- To keep false alarms rare, 3.7 uploads marks made from notification actions in the background (WorkManager/BGTask) instead of waiting for the next app start.

**Time zones.**
- `local` medications use `profiles.timezone` on the server. The app keeps the `self` profile's zone equal to the device zone (3.6).
- **Managed profiles keep their own zone, and guardians' devices plan their `local` medications in that zone (D4)**: grandma's 08:00 stays her 08:00 when the guardian travels. This changes Phase 2 behaviour for managed profiles (they followed the device zone); `self` profiles keep following the device zone, now synced to the server.
- Known limitation: between a device zone change and the next sync, server instants use the old zone. Keys are nominal and still match.
- DST is handled by the engine (`docs/spec/schedule.md` §3.1), with no detector-specific logic.

**Granularity and load bounds.**
- Latency ≤ X + 60 s + delivery.
- Work per tick is O(eligible profiles × schedules × 5 days × slots) engine steps. Each `expand` covers ≤ 10 min plus the engine's ±2-day date margin.
- Queries per batch are constant: profiles, schedules, snoozed keys, events, inserts. A test asserts this with a statement counter.
- Target: 10k eligible profiles per tick under 5 s on one worker. Beyond that, shard by `hashtext(profile_id) % N` across workers (follow-up, not built).

**Worker.** `backend/app/worker.py: WorkerSettings` with:
- functions `deliver_pushes`;
- crons `detect_missed_doses` (1 min), `deliver_pushes` (10 s), `erase_expired_accounts` (hourly, D2; the service function lands in 3.2b, the cron in 3.4), `cleanup_retention` (daily: invites, alerts, outbox, push tokens unused > 270 days);
- `on_startup` creating the engine, sessionmaker and push senders from `Settings`;
- an injectable clock in `ctx`.

Compose service `worker` uses the same image, `command: ["arq", "app.worker.WorkerSettings"]`, healthcheck `arq --check app.worker.WorkerSettings`. The same Redis is used, with ARQ's own key prefix (tests flush the DB anyway). Risk: ARQ is in maintenance mode. It is isolated behind `app/worker.py` and the job functions are plain async functions taking `(ctx, …)`, so it can be swapped.

---

## Push (milestone 3.4)

**Abstraction** (`backend/app/push/`):

```python
class PushPayload(BaseModel):            # extra="forbid"; the only way to build a payload
    v: Literal[1]; t: Literal["missed", "resolved", "link_accepted"]
    a: uuid.UUID | None   # alert id
    p: uuid.UUID | None   # subject profile id
    m: uuid.UUID | None   # medication id (opaque; text is rendered from local projected data)
    g: uuid.UUID | None   # grant id
    s: Literal["u"] | None  # unconfirmed variant

class PushMessage(BaseModel): token: str; provider: Provider; payload: PushPayload; collapse_id: str; apns_environment: ...
class SendResult(Enum): OK, INVALID_TOKEN, RETRY, FATAL
class PushSender(Protocol):
    provider: Provider
    async def send(self, message: PushMessage) -> SendResult: ...
```

Implementations:
- `FcmSender`: HTTP v1 over `httpx`; OAuth2 via a service-account JWT, RS256 with `pyjwt[crypto]`.
- `ApnsSender`: HTTP/2 (`httpx[http2]`), token auth with an ES256 `.p8` key.
- `RuStoreSender`: RuStore Push HTTP API with project id and service token. ADR 0008 records the endpoint and error codes from the docs.
- `FakePushSender` for tests (records messages, scriptable results).
- `DisabledPushSender`, chosen when a provider's settings are missing: drops the message with `dropped/provider_disabled`.

`build_senders(settings)` decides which are active.

**Settings** (all optional; secrets as `SecretStr`, placeholders in `infra/.env.example`): `FCM_PROJECT_ID`, `FCM_SERVICE_ACCOUNT_JSON_B64`, `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_PRIVATE_KEY_B64`, `APNS_TOPIC`, `RUSTORE_PROJECT_ID`, `RUSTORE_SERVICE_TOKEN`, `PUSH_MAX_ATTEMPTS=5`, `PUSH_STALE_AFTER_SECONDS=7200`.

**Token registration:** `PUT /v1/push-tokens/current`, body `{provider, token, apns_environment?}`, with `X-Device-ID` required. It touches the device and upserts (reassigning a token held by another account). `DELETE /v1/push-tokens/current` removes it. `POST /v1/auth/logout` also deletes the token of the device it is called with. `DELETE /v1/me` deletes all the user's tokens (D2); the app registers again after a restore.

**Provider per device (client decides, server sends to every token of the recipient):**
- iOS → `apns`, the raw APNs token from a native channel, so Firebase is not needed on iOS.
- Android with Google Play services and FCM configured → `fcm`.
- Otherwise Android with RuStore Push available and configured → `rustore`.
- Otherwise none. Family settings then show "alerts about relatives are not available on this device".

**Payload and rendering:**
- **Android (FCM/RuStore):** a data-only, high-priority message. A background handler (no network) reads the subject profile's display name and, for `shared` medications with "hide names" off, the medication name from local drift. It shows a local notification on channel `relatives_alerts_v1`, with an id in the app range (≥ `0x40000000`, ADR 0001 §3) derived from the alert id. If local data is missing, it uses the generic text.
- **iOS:** an alert push with `loc-key` (generic, from `Localizable.strings`), `thread-id = p`, `apns-collapse-id = a`, `mutable-content: 1`. That leaves room for a Notification Service Extension to personalize the text later (follow-up, Xcode target like the iOS widget).
- No medication names, doses, times or occurrence keys go over the wire. The occurrence key encodes the schedule time.
- A tap routes to the relative's day view.

**Delivery** (`app/services/push_outbox.py`, job `deliver_pushes`):
- Claims up to 200 pending rows with `FOR UPDATE SKIP LOCKED` and sends them concurrently (bounded semaphore).
- `OK` → `sent`, `push_tokens.last_success_at`.
- `INVALID_TOKEN` (FCM `UNREGISTERED`/404 or invalid-token 400; APNs 410 or `BadDeviceToken`; RuStore 404 `NOT_FOUND` or invalid-token 400) → delete the token, which cascades its pending rows.
- `RETRY` (5xx, 429 honoring `Retry-After`, network) → backoff 30 s, 2 min, 10 min, 30 min.
- Dropped after `PUSH_MAX_ATTEMPTS`, or when the alert is older than `PUSH_STALE_AFTER_SECONDS`.
- Logs carry `delivery_id`, provider, status and error code only, never the token or the payload.
- Duplicates after a crash between send and mark are collapsed by `collapse_id` (APNs) and the notification tag (all platforms).

---

## Invites and deep links

- **Create:**
  - `POST /v1/profiles/{profile_id}/invites` with body `{id, role}`.
  - The response returns the token **once**: `{id, role, expires_at, url: "https://{link_host}/i#<token>"}`.
  - TTL `INVITE_TTL_SECONDS` = 7 days. At most 5 active invites per profile (`409 too_many_invites`).
  - A replay of the same id gives `409 already_exists`; the client then creates a new invite.
  - An archived profile refuses invites (`409 read_only`, D1).
  - QR codes encode the same URL.
- **Preview:** `POST /v1/invites/preview {token}` returns `{inviter_display_name, profile_display_name, profile_kind, role, expires_at}`.
- **Accept** (the invitee confirms): `POST /v1/invites/accept {token}` locks the invite row, creates the grant, consumes the invite, and enqueues a `link_accepted` push to the owner, so the owner learns about new access and can revoke it. A replay by the same user returns the existing grant (200).
- **Error codes:** `invite_invalid` (unknown or revoked, including invites revoked by the owner's deletion request), `invite_expired`, `invite_used`, `invite_own_profile`, `already_linked`, `relatives_limit_reached` (flag on). The token is the capability, so distinct codes leak nothing. Rate-limited per user and IP.
- **Link host is config-driven (D6: domain not decided yet):**
  - Backend: `PUBLIC_LINK_BASE_URL` (per region). Until the owner picks a domain it stays a placeholder under the reserved `.invalid` TLD (`https://links-ru.pillpal.invalid`, `https://links-eu.pillpal.invalid`). Non-blocking: everything except link verification on real devices works with the placeholder.
  - `GET /.well-known/assetlinks.json` built from `ANDROID_PACKAGE_NAME` and `ANDROID_CERT_SHA256S` (upload key and Play signing key). `GET /.well-known/apple-app-site-association` built from `APPLE_TEAM_ID` and `IOS_BUNDLE_ID`. Both return 404 when unset.
  - `GET /i` is a static landing page ("open in PillPal / install"): no token, `Cache-Control: no-store`, `Referrer-Policy: no-referrer`, strict CSP.
  - Access logs already use route templates (`observability.py`), and the token is in the fragment anyway.
- **App:**
  - `PILLPAL_LINK_HOSTS` (dart-define, both regions' hosts).
  - Android `intent-filter android:autoVerify="true"`: scheme `https`, hosts from Gradle `manifestPlaceholders` (`pillpal.linkHostRu` / `pillpal.linkHostEu`, defaults `links-ru.pillpal.invalid` / `links-eu.pillpal.invalid`), `pathPrefix="/i"`.
  - iOS `com.apple.developer.associated-domains` = `applinks:$(PILLPAL_LINK_HOST_RU)` / `$(…_EU)` from `ios/Flutter/Links.xcconfig`. Manual capability step before a signed build, like Time Sensitive.
  - **No custom URL scheme in release**: another app could register it and intercept tokens.
  - In-app "Paste invite link" fallback for unverified domains.
  - A link whose host belongs to the other region is refused with "invite from another region" (TZ §1). Server-side, the token simply does not exist in the other region's DB.

---

## Account deletion grace and restore (milestone 3.2b, D2)

- **`DELETE /v1/me`** (password-confirmed, as today) → 204. Performs the request stage above. The response and `GET /v1/me` before it show nothing new; the app shows the date from its own clock + grace and wipes local data.
- **Login during the grace period** (`POST /v1/auth/login`): after a correct password (never before, so nothing leaks to a guesser) and while `erase_after > now`, it returns `403 account_pending_deletion` with `details: {restore_ticket, erase_after}`. The error envelope gains an optional `details` object (server-generated values only, never echoed input). The ticket is 256 bits, stored as `sha256` in Redis with TTL `ACCOUNT_RESTORE_TICKET_TTL_SECONDS` (600), single use (`GETDEL`). After `erase_after` the account behaves as unknown (`invalid_credentials`).
- **`POST /v1/auth/restore {restore_ticket}`** (rate-limited per IP; optional `X-Device-ID`) locks the user row, re-checks `erase_after > now`, clears the deletion columns, un-archives `owner_pending_deletion` profiles, touches the device and returns a fresh `TokenPair`. A used, expired or unknown ticket → `401 invalid_token`.
- **Register during the grace period** returns the usual `202` with the same body; the mail to the known address says the account is scheduled for deletion and how to restore it. The unique e-mail index guarantees no second account.
- **Password reset during the grace period** works as today and does not restore by itself; the next login offers the restore.
- **Access tokens** of a `pending_deletion` user are refused by `get_current_user` (401); refresh tokens were revoked by the request.
- **Erasure job** `erase_expired_accounts(session, now)`: selects `users WHERE erase_after <= now ORDER BY erase_after LIMIT n FOR UPDATE SKIP LOCKED`, re-checks, and calls `erase_account` (with the D1 transfer) per user in its own transaction. Hourly cron, so erasure completes within the grace period (ADR 0010 §4). Logs `account_erased` with the user id only.
- **Settings:** `ACCOUNT_DELETION_GRACE_DAYS=30` (validator `1..30`; lengthening needs legal review, ADR 0010), `ACCOUNT_ERASURE_JOB_INTERVAL_SECONDS=3600`, `ACCOUNT_RESTORE_TICKET_TTL_SECONDS=600`.

---

## App (milestones 3.6–3.9)

- **Data:**
  - drift schema v4: `access_scopes` (profile_id, role, kind, archived, cursor), `relative_links` (cached grants for offline display), `profile_device_settings` (reminders on this device per guardian profile, device-local), `push_state`.
  - New columns: `medications.redacted`, `schedules.redacted`, `profiles.missed_alert_minutes`, `profiles.missed_alerts_enabled`.
  - Scoped pull, eviction, the self-profile fix, reminder scope filter (no reminders for archived scopes), zone sync, managed-profile zone planning (D4), deterministic split ids.
- **Background upload of marks** (3.7): after a notification action, Android enqueues a one-off WorkManager job with a network constraint that runs `SyncEngine.flush()`; iOS pushes inside the existing `beginBackgroundTask` window. Token refresh is serialized across isolates by a lease row in drift: refresh tokens are single-use with reuse detection, so concurrent refreshes would revoke the family.
- **Screens** (3.8):
  - Family tab replaces `FamilyScreen`'s placeholder: "Видят меня", "Я вижу", "Подопечные".
  - Invite create: role choice and a preview of which medications this relative will see (ADR 0003 §7); the role text says editors cannot mark doses (D3).
  - Invite share: QR plus the system share sheet.
  - Invite accept: deep link or pasted link, preview, then confirm.
  - Relative detail: role edit (owner), "notify me about missed doses" (grantee), revoke or leave.
  - Managed profile create/edit: name, zone, alert minutes and on/off, co-guardian invite, "remind on this device".
  - Archived managed profile (D1): read-only banner, Today/History/PDF readable, "Delete archive" for guardians, no mark buttons.
  - Profile switcher (chip row) on Today, Medications and History. The relative's day view reuses Today with `profileId`: read-only for viewers; for editors `shared` medications and schedules are editable and there are **no mark buttons** (D3). Anonymous medications show "Лекарство" plus time and status.
  - Privacy explanations on the medication form.
  - Soft-limit gating from `GET /v1/me/features`.
  - Account deletion (D2): the dialog states the 30-day restore window and what happens to each managed profile (archive for co-guardians, or erased); login handles `account_pending_deletion` with a "Restore account" screen calling `POST /v1/auth/restore`.
- **Push** (3.9): FCM via `firebase_core`/`firebase_messaging`, initialized from dart-defines only when present (no `google-services` Gradle plugin, so builds work without `google-services.json`). RuStore Push plugin initialized only with a project id. iOS APNs through the native `pillpal/push` channel in `AppDelegate.swift`. Token registration on sign-in, restore and token refresh, deletion on sign-out. Payload parsing, local rendering, and tap routing.

---

## Milestones

| # | Milestone | Scope | Done when |
|---|---|---|---|
| 3.0 | Docs and contracts | This plan, ADRs 0005–0010, owner decisions D1–D6 recorded | ADRs merged |
| 3.1 | Dose-state contract | Spec, vectors, Python reference, Dart port in core, app uses core | Both suites run all vectors; app tests green |
| 3.2 | Backend: links, invites, permissions | Grants, invites, alert settings, well-known/landing, features flag, erasure of new tables | Endpoint matrix tests green |
| 3.2b | Backend: account deletion grace and restore | D2 request/restore/erase job function, D1 archive and ownership transfer | Deletion suite green, needle test green |
| 3.3 | Backend: scoped sync and authorization | Journal by scope, `POST /v1/sync/pull`, projection, editor/guardian writes, archived scopes, REST for guardians | Sync privacy suite green |
| 3.4 | Backend: push infrastructure and ARQ worker | Tokens, outbox, senders, worker (incl. `erase_expired_accounts` cron), compose | Delivery suite green, worker wiring test green |
| 3.5 | Backend: missed-dose detector | Alerts, watermark tick, resolution, retention | Detector suite green |
| 3.6 | App: scoped data layer | drift v4, scoped pull, eviction, reminder filter, zone sync, managed zone (D4) | Unit tests and host e2e green |
| 3.7 | App: background upload of marks | WorkManager/BGTask flush, refresh lease | Unit tests green, emulator `taken` phase asserts server event without app start |
| 3.8 | App: relatives UI, deep links, deletion/restore | Family tab, invites, QR, accept, switcher, day view, managed profiles, archive view, delete/restore | Widget tests green, debug APK and iOS build green |
| 3.9 | App: push | FCM/RuStore/APNs clients, registration, rendering, routing | Unit tests green; builds green without credentials |
| 3.10 | E2E, CI, cleanup | Relatives host e2e and emulator phase, remove `GET /v1/sync/pull`, docs | All workflows green |

### 3.0 Docs and contracts
- **Files:**
  - `docs/phase3-plan.md`
  - `docs/adr/0005-relatives-and-permissions.md`
  - `docs/adr/0006-sync-scopes-and-privacy-projection.md`
  - `docs/adr/0007-missed-dose-detection.md`
  - `docs/adr/0008-push-delivery.md`
  - `docs/adr/0009-invite-links.md`
  - `docs/adr/0010-account-deletion-grace-and-restore.md`
  - `CLAUDE.md` (current phase)
- **ADR 0008 cites sources** (as ADR 0001 did) for the RuStore HTTP API and Flutter plugin (name, version, Maven repo, init), FlutterFire's init without google-services, and APNs/FCM error codes. Items it could not verify are marked "to verify in 3.9".
- **Reviewers:** `architect`, `privacy-compliance-reviewer`, `security-reviewer`, `offline-sync-reviewer`.
- **Done when:** merged with owner sign-off. Risk: low.

### 3.1 Dose-state contract (spec, vectors, Python, Dart in one PR)
- **Files:**
  - `docs/spec/dose-state.md`
  - `spec/dose-state-vectors/{schema.json,marks.json,snooze.json,missed.json}`
  - `spec/validate_vectors.py` (validate the new directory)
  - `backend/app/domain/dose_state.py`
  - `backend/tests/domain/test_dose_state_vectors.py`
  - `packages/pillpal_core/lib/src/doses/occurrence_state.dart` and export from `lib/pillpal_core.dart`
  - `packages/pillpal_core/test/doses/dose_state_vectors_test.dart`
  - `app/lib/src/features/doses/dose_status.dart` and `app/lib/src/reminders/reminder_inputs.dart` delegate to core (behaviour unchanged)
- **Test first:** vectors covering no events; taken; skipped; taken→undo; taken→undo→taken; skipped then taken (last by `at`); equal `at` (larger id wins); two snoozes (latest wins); snooze undone; snooze with `snooze_until` before the occurrence instant (`due = max`); events of other keys ignored; `missed` at `due + X − 1 µs` / exactly `due + X`. Python and Dart suites fail until implemented.
- **Reviewers:** `schedule-engine-guardian` (shared semantics, same discipline as the engine), `code-reviewer`.
- **Done when:** both suites run all vectors, `python spec/validate_vectors.py` passes, and existing app tests are unchanged and green. Risk: medium, because it touches live Today and reminder logic. The refactor must be behaviour-preserving.

### 3.2 Backend: links, invites, permissions
- **Migrations:** `0004_profile_grants`, `0005_invites`, `0006_profile_missed_alert_settings`.
- **Files:**
  - `backend/app/db/relatives.py`, `app/db/__init__.py`, `app/db/models.py` (Profile columns)
  - `app/services/access.py`:
    ```python
    Role = Literal["owner", "guardian", "editor", "viewer"]
    async def role_for_profile(session, user_id, profile_id) -> Role | None
    def accessible_profiles(user_id, roles: frozenset[Role]) -> Select  # SQL predicate; active grants only (3.2b adds the pending/archived terms)
    ```
  - `app/domain/privacy.py`:
    ```python
    def project_medication(data, role) -> dict | None
    def project_schedule(...)
    def project_dose_event(...)
    def project_profile(...)
    ```
  - `app/services/invites.py`, `app/services/grants.py`, `app/schemas/relatives.py`, `app/api/relatives.py`, `app/api/links.py`, `app/api/auth.py` (`GET /v1/me/features`)
  - `app/config.py`: `invite_ttl_seconds`, `max_active_invites_per_profile`, `public_link_base_url` (placeholder default in dev, required in prod), `android_package_name`, `android_cert_sha256s`, `apple_team_id`, `ios_bundle_id`, `feature_soft_limits=False`, `soft_limit_relatives=3`, `soft_limit_pdf_reports`
  - `app/schemas/entities.py` (Profile alert fields; `ProfileData` optional with keep-on-absent), `app/services/sync.py` (keep-on-absent), `app/services/erasure.py`, `app/services/personal_data.py`, `app/main.py` (routers)
  - `spec/openapi.json`
- **Endpoints:**

  | Method + path | Auth rule |
  |---|---|
  | `POST /v1/profiles/{profile_id}/invites` | caller is the owner of a live profile; `guardian` only for managed; foreign or missing → 404 |
  | `GET /v1/profiles/{profile_id}/invites` | owner; no tokens in the response |
  | `DELETE /v1/invites/{invite_id}` | owner of the invite's profile; idempotent 204 |
  | `POST /v1/invites/preview`, `POST /v1/invites/accept` | any authenticated user holding the token; not the owner; rate-limited (`limit_by_user`) |
  | `GET /v1/grants` | `outgoing` = grants on owned profiles (grantee's self display name, role, created_at); `incoming` = caller's grants |
  | `PATCH /v1/grants/{grant_id}` | field-level: owner may set `role`; grantee may set `notify_missed`; anyone else → 404 |
  | `DELETE /v1/grants/{grant_id}` | owner or grantee; 204 |
  | `GET /v1/me/features` | any user: `{soft_limits, relatives_limit, pdf_reports_limit}` |
  | `GET /.well-known/assetlinks.json`, `GET /.well-known/apple-app-site-association`, `GET /i` | public, static from Settings, 404 when unset |

- **Tests first:**
  - `tests/test_invites.py`: create, preview, accept happy path; expired, used, revoked; own profile; already linked; guardian on a self profile → 422; active-invite cap; replay of create id → 409; accept replay → 200; concurrent double-accept by two users → one grant; token never in the DB (only the hash) and never in responses after create.
  - `tests/test_grants.py`: the permission matrix for PATCH/DELETE; 401; 422; foreign → 404.
  - `tests/test_soft_limits.py`: flag off means no limit; flag on means 409 on the 4th relative.
  - `tests/test_links.py`: well-known files from Settings, 404 when unset, `/i` headers.
  - `tests/domain/test_privacy_projection.py`: every field of `MedicationOut`, `ScheduleOut`, `DoseEventOut` is classified. A new field must be added to the projection table or the test fails.
  - DB trigger tests (grantee = owner, guardian on self, grant on a tombstone).
  - Erasure needle test extended; inventory test.
  - `test_config_and_migrations` round-trip of 0004–0006.
- **Reviewers:** `security-reviewer`, `privacy-compliance-reviewer`, `code-reviewer`.
- **Done when:** `/verify` backend is green and the OpenAPI snapshot is refreshed. Risk: medium, because this is a new authorization surface.

### 3.2b Backend: account deletion grace and restore (D2, D1)
- **Migrations:** `0007_user_deletion_grace`, `0008_profile_archive` (also replaces the grant and invite guard functions).
- **Files:**
  - `app/db/models.py` (User and Profile columns)
  - `app/services/account_deletion.py` (new): `request_deletion`, `restore_account`, `erase_expired_accounts(session, now)`
  - `app/services/erasure.py`: D1 transfer before the existing deletes; multi-owner journal lock
  - `app/services/auth.py`: login → `account_pending_deletion` with a restore ticket; register mail variant; `delete_account` calls `request_deletion`
  - `app/services/restore_tickets.py` (Redis, hashed, `GETDEL`)
  - `app/deps.py`: `get_current_user` refuses `pending_deletion`
  - `app/services/access.py`: active-grant predicate (owner and grantee not pending), archived profiles readable only by owner/guardians
  - `app/services/entities.py`, `app/services/dose_events.py`, `app/services/invites.py`, `app/services/grants.py`: `409 read_only` on archived profiles; archive deletion by any guardian
  - `app/errors.py`: optional `details` in the envelope
  - `app/api/auth.py`: `POST /v1/auth/restore`
  - `app/config.py`: `account_deletion_grace_days=30` (validator `1..30`), `account_erasure_job_interval_seconds=3600`, `account_restore_ticket_ttl_seconds=600`
  - `backend/README.md` (deletion section, `doc-updater`), `infra/.env.example`, `spec/openapi.json`
- **Tests first** (`tests/test_account_deletion.py`, `tests/test_account_restore.py`, `tests/test_managed_archive.py`; fake clock, real PG and Redis):
  - delete → login with the right password gives `403 account_pending_deletion` with a ticket; a wrong password gives the usual `401 invalid_credentials` (no oracle);
  - restore with the ticket returns tokens, and all data (profiles, medications, schedules, dose events) and grants are back; the ticket is single use; an expired ticket → 401;
  - relatives lose access during the grace period (REST 404, pull lists the scope in `revoked`) and regain it on restore (scope back, backfill from 0);
  - refresh tokens of every family are invalid after the delete; an access token issued before is refused;
  - registration during the grace period returns the same 202 body and creates no second user; the mail variant is sent;
  - password reset during the grace period works and the next login still offers restore;
  - the user's push tokens are deleted and their open invites revoked;
  - managed profile with a co-guardian: archived during the grace period (co-guardian reads, writes → `read_only`, invites refused); after the job the profile survives with the co-guardian as owner (`owner_erased`), viewer/editor grants gone, history intact; a second co-guardian keeps a guardian grant;
  - managed profile without co-guardians: erased by the job;
  - any guardian may delete the archive; nobody may un-archive it after `owner_erased`;
  - restore before the job un-archives `owner_pending_deletion` profiles;
  - the job after `erase_after` removes everything (existing needle test, driven through request + job); `erase_after` is at most `grace` after the request; the job before `erase_after` does nothing; concurrent restore and job → exactly one wins;
  - migration round-trip of 0007–0008; CHECK constraints (archive only on managed, both-or-neither columns).
- **Reviewers:** `privacy-compliance-reviewer`, `security-reviewer`, `offline-sync-reviewer` (scope visibility), `code-reviewer`.
- **Done when:** `/verify` backend is green; the cron is wired in 3.4. Risk: medium-high, because it changes a destructive path and the auth flow.

### 3.3 Backend: scoped sync and authorization
- **Migration:** `0009_sync_changes_scope`. Backfill in one step is allowed only because no stand exists; the PR body says so.
- **Files:**
  - `app/services/changes.py`: `lock_journal(session, owner_ids: Iterable[UUID])`, `record_change(session, profile_id, …)`
  - `app/services/scopes.py`: `resolve_batch_owners`, `lock_for_profile`
  - `app/services/entities.py`: loaders take `actor: Actor(user_id, need: Literal["read", "write"])` and filter by `accessible_profiles` with full-access roles
  - `app/services/sync.py`: editor rules (D3), archived scopes, multi-owner locking
  - `app/services/sync_pull.py`: `pull_scoped(...)`, projection, `privacy`-op handling, `archived` flag
  - `app/services/dose_events.py`: access-scoped
  - `app/api/sync.py`: `POST /v1/sync/pull`
  - `app/api/resources.py`: owner or guardian; editors and viewers → 404
  - `app/deps.py`: `JournalLock` replaced for profile-addressed routes
  - `app/schemas/entities.py`: `ScopedPullRequest`, `ScopedPullResponse`, `ScopeOut`, `Change.scope`
  - `backend/README.md` sync section (`doc-updater`), `spec/openapi.json`
- **Tests first:**
  - `tests/test_sync_scopes.py`:
    - a new grant backfills from 0 across pages;
    - a revoked scope is listed in `revoked` with no data;
    - never-existed and foreign scopes give an identical response;
    - limit cap; 422 on more than 50 cursors; 401;
    - deterministic cross-scope order;
    - an owner's managed-profile deletion revokes the guardians' scope;
    - an archived scope is listed with `archived: true` for guardians and is absent for viewers/editors.
  - `tests/test_sync_privacy.py`:
    - viewer sees `shared` in full, `anonymous` redacted (assert no name, notes, stock, dose, or event note/device_id), `hidden` absent with its children absent;
    - shared→hidden gives a medication `delete`, children skipped;
    - hidden→shared gives the medication plus all schedules and events;
    - shared→anonymous overwrites with redacted copies;
    - a guardian sees everything.
  - `tests/test_sync_editor.py`:
    - editor upserts a shared medication: applied, journaled in the owner scope, the owner pulls it;
    - privacy change by an editor → `forbidden_field`;
    - editor creates a non-shared medication → rejected;
    - write to anonymous or hidden → `not_found`;
    - **editor dose events (taken, skipped, snoozed, undo) on a shared or anonymous medication → `forbidden`; on hidden → `not_found`** (D3);
    - profile write → `read_only`;
    - viewer write → `not_found`;
    - LWW between owner and editor converges (extend `test_sync_convergence.py`).
  - `tests/test_sync_archive.py`: every write into an archived scope → `read_only`; a guardian's profile delete is applied.
  - `tests/test_access_rest.py`: REST matrix (guardian 200; editor and viewer 404; archived → `409 read_only` on writes).
  - `test_sync_journal.py`: concurrent owner and editor transactions on one scope keep seq order equal to commit order. A multi-owner batch does not deadlock against REST writes (lock order).
  - All existing tests stay green, including `GET /v1/sync/pull`.
- **Reviewers:** `offline-sync-reviewer`, `security-reviewer`, `privacy-compliance-reviewer`, `code-reviewer`.
- **Done when:** `/verify` backend is green. The PR body flags a sync protocol change and a migration. Risk: **high**, because it touches the core sync invariant.

### 3.4 Backend: push infrastructure and ARQ worker
- **Dependencies:** `arq`, `httpx[http2]` (moved to runtime), `pyjwt[crypto]`; `uv.lock` updated.
- **Migrations:** `0010_push_tokens`, `0011_push_outbox`.
- **Files:**
  - `app/db/push.py`
  - `app/push/{__init__,base,fcm,apns,rustore,fake,disabled,registry}.py`
  - `app/schemas/push.py`, `app/services/push_tokens.py`, `app/services/push_outbox.py`, `app/api/push.py`
  - `app/services/auth.py` (logout deletes the device token), `app/services/account_deletion.py` (deletion request deletes all tokens)
  - `app/services/invites.py` (`link_accepted` enqueue)
  - `app/worker.py` (crons include `erase_expired_accounts`, hourly)
  - `app/config.py` (push settings, `prod` validator: an enabled provider needs all its fields)
  - `infra/docker-compose.yml` (`worker` service), `infra/.env.example`, `CLAUDE.md` commands (`doc-updater`)
- **Endpoints:** `PUT /v1/push-tokens/current`, `DELETE /v1/push-tokens/current`: authenticated, `X-Device-ID` required, scoped to the caller's own device.
- **Tests first:**
  - `tests/push/test_{fcm,apns,rustore}_sender.py` with `httpx.MockTransport` (provider HTTP is a true external): request shape, auth header, collapse id, error-code → `SendResult` mapping.
  - `tests/test_push_tokens.py`: upsert, reassignment across accounts, logout removal, deletion-request removal, 401, 422.
  - `tests/test_push_outbox.py` on real PG and Redis with `FakePushSender`: OK → sent; RETRY backoff; INVALID_TOKEN deletes the token and its pending rows; stale → dropped; two concurrent claimers never send the same row; disabled provider → dropped.
  - `tests/test_push_payload_privacy.py`: `PushPayload` rejects unknown keys; the DB CHECK rejects a hand-written payload with a `name` key; serialized payloads contain only uuid, enum and `v` values.
  - `tests/test_worker_wiring.py`: `arq.worker.Worker(burst=True)` runs `deliver_pushes` and `erase_expired_accounts` against real Redis.
- **Reviewers:** `security-reviewer` (secrets, outbound HTTP, deps), `privacy-compliance-reviewer` (third parties per region), `code-reviewer`.
- **Done when:** `/verify` backend is green, the Docker image builds, and `docker compose up` starts `worker` with every provider disabled. Risk: medium.

### 3.5 Backend: missed-dose detector
- **Migrations:** `0012_missed_dose_alerts` (with `detector_state`), `0013_dose_events_snooze_index`.
- **Files:**
  - `app/db/alerts.py`
  - `app/domain/missed.py`: pure, `find_missed(occurrences, events_by_key, X, window) -> list[Missed]`
  - `app/services/missed_doses.py`: tick, recipients, variant
  - `app/services/dose_events.py`: resolution on a late mark
  - `app/worker.py`: crons
  - `app/config.py`: `detector_max_window_seconds=600`, `detector_max_catchup_seconds=21600`, `detector_profile_batch=500`
- **Tests first:**
  - `tests/domain/test_missed.py`.
  - `tests/test_missed_detector.py` (fake clock; real PG and Redis; `FakePushSender`):
    - missed after X → one alert and one delivery per recipient token; the next tick produces nothing;
    - taken, or skipped, before due + X → nothing;
    - undo of taken → alert;
    - snoozed → alert only at `snooze_until + X`; re-snooze moves it;
    - `hidden` → only full-access recipients; `anonymous` → alert with ids only;
    - schedule created after the occurrence → nothing;
    - grant created after due → that recipient excluded;
    - `missed_alerts_enabled=false` → nothing; `notify_missed=false` → recipient excluded;
    - managed owner receives alerts; a self owner never does;
    - **archived profile → nothing; owner `pending_deletion` → nothing; recipient `pending_deletion` → excluded** (D1, D2);
    - `local` medication uses `profiles.timezone` (a managed profile's own zone, D4), `fixed` uses `fixed_tz` (Europe/Berlin gap occurrence);
    - owner devices last seen before the occurrence → `unconfirmed` (D5);
    - worker downtime → catch-up in ≤ 10-min windows with no duplicates; beyond 6 h → skipped and counted;
    - two concurrent ticks → one runs (`NOWAIT`);
    - constant statement count per profile batch.
  - `tests/test_missed_resolution.py`: a late `taken` via sync push resolves the alert and enqueues `resolved` for each recipient that got `missed`; a second late event does nothing.
  - Log-capture test: no medication name or occurrence key in detector logs.
- **Reviewers:** `schedule-engine-guardian` (tz resolution and engine use), `offline-sync-reviewer` (late events), `privacy-compliance-reviewer`, `code-reviewer`.
- **Done when:** `/verify` backend is green and vectors parity holds. Risk: high, because false or duplicate alarms erode trust.

### 3.6 App: scoped data layer
- **Files:**
  - `app/lib/src/data/db/tables.dart`, `database.dart` (schema v4 with migration step; `evictScope`; `wipeAccountData` coverage)
  - `data/api/sync_api.dart`, `sync_dto.dart` (scoped pull, `scope`, `redacted`, `archived`)
  - `data/sync/sync_engine.dart` (cursor map; `revoked` → evict; role change → evict and re-pull)
  - `data/sync/server_state_applier.dart` (foreign-scope rules)
  - `data/sync/outbox_pusher.dart` (park `not_found`/`read_only`/`forbidden`/`forbidden_field`; drop the outbox of evicted entities)
  - `data/repositories/access_repository.dart` (new)
  - `features/doses/dose_providers.dart`: `selfProfileProvider` = `kind == 'self'` **and** role `owner`
  - `reminders/reminder_inputs.dart`: only `owner`/`guardian` scopes that are not archived and have the device toggle on; managed profiles' `local` medications planned in `profiles.timezone` (D4); `self` profiles keep the device zone
  - `data/repositories/profiles_repository.dart`: `syncDeviceZone()` updates the self profile's zone when the device zone differs from the last reported one; called from `reminders/reminder_scope.dart` on start and resume
  - `data/repositories/schedules_repository.dart`: deterministic continuation ids, UUID v5 of `{schedule_id}/{split_date}`. This closes the ADR 0003 limitation, which editors make likelier.
  - `parseScheduleRow` helper for redacted rules
- **Tests first:**
  - `test/data/sync/scoped_pull_test.dart` (fake HTTP: cursor map, paging, revoked, role change, archived flag);
  - `test/data/sync/foreign_scope_applier_test.dart` (hard delete, event overwrite, redacted rows);
  - `test/data/db/migration_v4_test.dart` (legacy cursor → scopes);
  - `test/reminders/reminder_inputs_scopes_test.dart` (a viewer or editor scope never yields reminders; an archived scope never yields reminders; managed `local` medication at 08:00 Europe/Samara stays 08:00 Samara on a device in Europe/Berlin; `self` follows the device zone);
  - `test/data/self_profile_test.dart` (a relative's self profile is never "mine");
  - `test/data/split_ids_test.dart`;
  - `test_e2e/scoped_sync_test.dart` (host vs real backend: owner and viewer accounts, privacy matrix, revocation evicts).
- **Reviewers:** `offline-sync-reviewer`, `privacy-compliance-reviewer`, `notifications-specialist` (reminder scope and zone change), `code-reviewer`.
- **Done when:** `app.yml` (analyze, tests, e2e) and `app-emulator.yml` are green; CI only. Risk: high.

### 3.7 App: background upload of marks
- **Dependency:** `workmanager` (Android WorkManager; iOS not used); pubspec lock regenerated by `app-scaffold.yml`.
- **Files:**
  - `app/lib/src/reminders/background_handler.dart` (enqueue flush after a recorded action)
  - `app/lib/src/data/sync/background_flush.dart` (new: push-only `SyncEngine.flush()`, guarded by account binding)
  - `app/lib/src/data/auth/refresh_lease.dart` (new: drift row lease serializing refresh across isolates; refresh only while holding it; on contention re-read tokens)
  - `ios/Runner/AppDelegate.swift` (flush inside the existing background task window)
  - ADR 0001 addendum: background network is now allowed for outbox flush only
- **Tests first:**
  - `test/data/auth/refresh_lease_test.dart`: two concurrent refreshers produce one refresh request, and the other reuses the new tokens.
  - `test/data/sync/background_flush_test.dart`: account-changed guard, no pull, outbox order kept.
  - Emulator: the `taken` phase asserts the backend has the event **before** the app is started again.
- **Reviewers:** `notifications-specialist`, `offline-sync-reviewer`, `security-reviewer` (token handling), `code-reviewer`.
- **Done when:** `app.yml` and `app-emulator.yml` are green. Risk: high, because refresh-token reuse would sign users out.

### 3.8 App: relatives UI, deep links, deletion and restore
- **Dependencies:** `qr_flutter`, `share_plus`, `app_links`.
- **Files:**
  - `app/lib/src/features/family/{family_screen,family_providers,invite_create_screen,invite_share_sheet,invite_accept_screen,relative_detail_screen,managed_profile_form,profile_switcher,archived_profile_banner}.dart`
  - `app/lib/src/data/api/relatives_api.dart` (+ DTOs), `data/repositories/relatives_repository.dart`
  - `app/lib/src/links/{invite_link,link_listener}.dart`
  - `app/lib/src/data/config.dart` (`LinkConfig.fromEnvironment`)
  - `app/lib/src/features/auth/{restore_account_screen,login_controller}.dart` (`account_pending_deletion` → restore), `features/settings/delete_account_dialog.dart` (grace text, managed-profile consequences)
  - `routing/router.dart`, `routing/routes.dart` (`/family/invite/new`, `/family/accept`, `/family/profile/:profileId`, `/auth/restore`, profile-parameterized Today, Medications, History)
  - Today, Medications and History providers parameterized by `profileId`
  - `features/medications/medication_form.dart` (privacy explanations; editors see only `shared`)
  - `features/report/report_service.dart` (relative PDF from projected data; archives readable)
  - l10n ARB RU and EN
  - Android: `AndroidManifest.xml` intent-filter, `build.gradle.kts` placeholders; Flutter deep linking disabled in favour of `app_links`
  - iOS: `Runner.entitlements`, `Flutter/Links.xcconfig`
  - Owner manual checklist in `docs/phase3-plan.md`
- **Tests first:**
  - `test/links/invite_link_test.dart` (fragment token, wrong host, other-region host, malformed);
  - widget tests for each screen;
  - redacted medications never show name or dose (Today, History, PDF);
  - a viewer has no mark buttons; **an editor has no mark buttons** (D3) and cannot edit anonymous medications;
  - an archived profile shows the banner, no mark or edit controls, and readable history; "Delete archive" for guardians;
  - login → `account_pending_deletion` → restore screen → tokens stored and a full pull; the deletion dialog lists managed-profile consequences;
  - soft-limit gating when the flag is on.
- **Reviewers:** `privacy-compliance-reviewer`, `security-reviewer` (deep links, restore ticket handling), `code-reviewer`.
- **Done when:** `app.yml`, `app-ios.yml` and `app-release.yml` are green. Risk: medium.

### 3.9 App: push
- **Dependencies:** `firebase_core`, `firebase_messaging`, `flutter_rustore_push` (versions pinned in this milestone, see ADR 0008 §9).
- **Files:**
  - `app/lib/src/push/{push_config,push_service,fcm_client,rustore_client,apns_channel,push_payload,relatives_alert_notifier,push_background_handler}.dart`
  - `ios/Runner/AppDelegate.swift` (`pillpal/push` channel, `registerForRemoteNotifications`), `Runner.entitlements` (`aps-environment`; manual capability step)
  - Android: `settings.gradle.kts` (RuStore Maven), `build.gradle.kts` (`rustoreProjectId` placeholder, default empty)
  - `.github/workflows/app-release.yml` (FCM dart-defines and RuStore id from repo **variables**; absent → disabled)
- **Tests first:**
  - `push_payload_test` (strict parse; unknown `t` ignored);
  - `push_service_test` (provider selection with fakes: GMS → fcm; no GMS and RuStore → rustore; neither → none; registration on sign-in, restore and token refresh; deletion on sign-out);
  - `relatives_alert_notifier_test` (text from local data; generic fallback; "hide names" respected; id in the app range; `resolved` replaces; `unconfirmed` text).
- **Reviewers:** `notifications-specialist`, `privacy-compliance-reviewer`, `security-reviewer`, `code-reviewer`.
- **Done when:** all app workflows are green **without** any push credentials. Risk: medium; the RuStore plugin is the unknown.

### 3.10 E2E, CI, cleanup
- **Files:**
  - `app/test_e2e/relatives_test.dart` (includes delete → restore for a relative's access)
  - `.github/scripts/emulator/{run.sh,host_control.py}`: new `relatives` phase. The host creates an owner with shared, anonymous and hidden medications plus an invite via the API. Then `adb shell am start -a android.intent.action.VIEW -d "https://<placeholder host>/i#<token>" com.pillpal.pillpal` (explicit package, no verification needed). The app accepts; the Family tab lists the owner; the day view shows the shared name, a generic anonymous entry and no hidden one; the host revokes; after resume the data is gone.
  - Backend removes `GET /v1/sync/pull` (+ tests, `spec/openapi.json`)
  - `CLAUDE.md`, `backend/README.md` (`doc-updater`)
  - Manual checklist: real FCM, APNs and RuStore receipt; universal/app links on a verified domain (after D6); iOS scenarios
- **Reviewers:** `e2e-runner`, `code-reviewer`, `security-reviewer` (CI).
- **Done when:** every workflow is green, including the emulator `relatives` phase. Risk: medium.

---

## Migrations and compatibility

| Revision | Milestone | Concern | Downgrade |
|---|---|---|---|
| `0004_profile_grants` | 3.2 | table and guard trigger | drop |
| `0005_invites` | 3.2 | table and trigger | drop |
| `0006_profile_missed_alert_settings` | 3.2 | two columns with defaults (metadata-only) | drop columns |
| `0007_user_deletion_grace` | 3.2b | two nullable columns, CHECKs, partial index | drop (refused while a row is pending, so no deletion request is silently lost) |
| `0008_profile_archive` | 3.2b | two nullable columns, CHECKs, guard functions refuse archived profiles | restore previous guard functions, drop columns (refused while a profile is archived) |
| `0009_sync_changes_scope` | 3.3 | journal re-keyed to `profile_id`, `privacy` op | restore `user_id` from owner, drop `privacy` rows |
| `0010_push_tokens` / `0011_push_outbox` | 3.4 | tables | drop |
| `0012_missed_dose_alerts` | 3.5 | alerts and `detector_state` | drop |
| `0013_dose_events_snooze_index` | 3.5 | partial index | drop index |

- No revision rewrites `dose_events`. `0009` backfills the journal, which is acceptable pre-release. With a live stand it would be add-nullable → batched backfill → `SET NOT NULL`.
- Schedule rule `v` is unchanged. Engine spec and schedule vectors are unchanged, apart from a clarifying note in `docs/spec/schedule.md` §3.1 on how callers resolve `local` for managed profiles (D4). The new dose-state spec has its own vectors.
- **Sync protocol:** `POST /v1/sync/pull` added (3.3) and `GET` removed (3.10); `Change.scope`; `ScopeOut.archived`; redacted payloads; profile alert fields optional with keep-on-absent; new rejection codes `read_only`, `forbidden` and `forbidden_field`. Clients in the field: none. drift schema v4 migrates the cursor.
- **Auth API:** `DELETE /v1/me` keeps its contract (204) but no longer erases at once; login may return `403 account_pending_deletion` with `details`; new `POST /v1/auth/restore`. The error envelope gains an optional `details` object.

## Privacy and region impact

- New personal data: links between accounts (grants, invites), device push tokens, and missed-dose alerts, which are medical. Device liveness is disclosed in the `unconfirmed` alert text (D5: accepted). All of it is in the erasure transaction and the table inventory. Retention: invites 30 days after end of life, alerts 30 days, outbox 7 days, stale tokens 270 days.
- **Account deletion (D2):** processing for relatives, detection and push stops at the request; data is kept, blocked, for at most `ACCOUNT_DELETION_GRACE_DAYS` (30) and then erased. ADR 0010 records the legal rationale (152-FZ art. 21(5), GDPR art. 12(3)/17, App Store 5.1.1(v), Google Play account deletion policy) and that an indefinite archive would not be compliant.
- **Managed archive (D1):** after the owner's erasure, a managed profile's medical data (about the managed person, not the deleted user) stays with its co-guardians. Device ids on retained rows are opaque strings with no FK; the `devices` rows that could link them to the deleted user are erased. Notes written by the former owner remain part of the managed person's history. Flagged to `privacy-compliance-reviewer` for the Phase 5 legal basis of managed profiles.
- Privacy is projected server-side in one pure module for pull. REST is closed to relatives. Push payloads carry ids only. The relative's PDF is built from projected local data. Logs carry ids and codes only, with a capture test in 3.5.
- Third parties: FCM (Google) and APNs (Apple) in both regions, RuStore (VK) in RU. Only tokens and opaque ids are sent. This must be listed per region in the Phase 5 privacy documents; ADR 0008 records it.
- Regions: invites and grants live in one regional DB, so cross-region acceptance is impossible on the server. The app refuses other-region link hosts. No shared queue: the worker uses the region's Redis.
- Consent (rule 6): a grant is initiated by the data subject (owner) after a disclosure of what is shared. Formal consent records and the legal basis for managed profiles of third persons are Phase 5; this is flagged to `privacy-compliance-reviewer`.

## Reviewers to run (agents)
`architect` (3.0); `schedule-engine-guardian` (3.1, 3.5); `offline-sync-reviewer` (3.2b, 3.3, 3.5, 3.6, 3.7); `privacy-compliance-reviewer` (3.0, 3.2–3.6, 3.8, 3.9); `security-reviewer` (3.2–3.4, 3.7–3.10); `notifications-specialist` (3.6, 3.7, 3.9); `e2e-runner` (3.10); `code-reviewer` and `doc-updater` on every PR.

## Done when (phase)
- [ ] `/verify` green, backend and core: ruff, format, mypy strict, pytest ≥ 85% coverage on real PG and Redis, Dart format, analyze and test (CI).
- [ ] Vectors parity: `python spec/validate_vectors.py` covers both `schedule-vectors` and `dose-state-vectors`; Python and Dart run all of them.
- [ ] `app.yml` (including host e2e), `app-emulator.yml` (including `relatives`), `app-release.yml` and `app-ios.yml` green without push credentials.
- [ ] `alembic upgrade head` / `downgrade -1` round-trip for 0004–0013; `spec/openapi.json` refreshed.
- [ ] Manual checklist done on devices once credentials and a domain exist (not blocking merge).

## Out of scope / follow-ups
- iOS Notification Service Extension (personalized relative alerts).
- Silent "sync now" pushes to co-guardians, so their reminders settle sooner.
- Detector sharding.
- Local nicknames for relatives.
- "Request access" (reverse invite).
- Un-archiving a D1 archive after `owner_erased` (for example, a co-guardian taking it over as an active profile).
- Phase 2 leftovers that stay unchanged: iOS widget, iOS backup exclusion, SQLCipher decision.
- Phase 4/5: catalog, OAuth, export endpoint, consent records, regional routing.

## ADRs
- **0005 relatives and permissions:** roles, matrix (D3), managed guardianship and the D1 archive, invites lifecycle, soft limits.
- **0006 sync scopes and privacy projection:** journal by profile, owner-keyed lock, scoped pull, eviction, re-journaling, editor writes, archived and inactive scopes.
- **0007 missed-dose detection:** watermark windows, final-due rule, offline policy and `unconfirmed` (D5), tz resolution (D4), ARQ worker, load bounds.
- **0008 push delivery:** providers, payload, rendering, tokens, retries, Android without google-services, iOS native APNs, third parties per region.
- **0009 invite links:** URL with fragment token, link host config (D6), `.well-known`, no custom scheme in release, other-region handling.
- **0010 account deletion grace and restore:** D2, interplay with D1, legal rationale.
- **ADR 0001 addendum** (in 3.7): background outbox flush and refresh lease.

---

## Owner decisions (2026-10-16)

| # | Topic | Decision | Where it lands |
|---|---|---|---|
| D1 | Managed profile when its owner's account goes away | It becomes a **read-only archive** for co-guardians: reminders and missed-dose alerts stop, no edits, no new invites; co-guardians keep the history (Today, History, PDF readable) and any co-guardian may delete the archive. With no co-guardians the profile is erased with the owner's data. Modelled as `profiles.archived_at` + `archive_reason`, enforced server-side (writes → `read_only`, detector skips, invites refused). At the final erasure ownership moves to the earliest co-guardian so the archive survives the owner's hard erase. | ADR 0005 §5, ADR 0010; 3.2b, 3.3, 3.5, 3.6, 3.8 |
| D2 | Account deletion | An **archive with restore**, superseding Phase 1's immediate erase: `DELETE /v1/me` sets `pending_deletion` (`users.deletion_requested_at`, `users.erase_after`), revokes all refresh-token families and push tokens, hides the account's profiles from relatives (grants kept but inactive), stops missed-dose detection for its profiles, and turns its managed profiles into D1 archives. Login during the grace period returns `account_pending_deletion` with a short-lived restore ticket; `POST /v1/auth/restore` restores everything without re-entering data. Registration with the same e-mail returns the usual generic response and creates no second account. After the grace period an ARQ job hard-erases via `erase_account` (plus the D1 transfer). **Grace = 30 days**, `ACCOUNT_DELETION_GRACE_DAYS`. | ADR 0010; 3.2b, 3.4 (cron), 3.8 |
| D3 | Does `view+edit` include marking doses? | **No.** Editors edit `shared` medications and schedules only; dose events from editors are `rejected/forbidden`. Guardians of managed profiles mark doses. | ADR 0005 §2, ADR 0006; 3.3, 3.8 |
| D4 | Zone of managed profiles' `local` medications on guardians' devices | **The managed profile's zone** (grandma's 08:00 stays her 08:00). `self` profiles keep following the device zone, synced to the server. | ADR 0007 §5; 3.6 |
| D5 | `unconfirmed` variant of missed-dose alerts ("no confirmation, phone not synced since …") | **Yes.** | ADR 0007 §4; 3.5, 3.9 |
| D6 | Invite link domain | **Not decided yet.** Config-driven placeholder `*.pillpal.invalid` until the owner provides a domain; non-blocking. | ADR 0009; 3.2, 3.8, 3.10 manual checklist |
| — | Already fixed by the TZ | Default missed threshold 30 min (configurable per profile, 5–720); RuStore Push included. | ADR 0007, ADR 0008 |
