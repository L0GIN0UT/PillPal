# ADR 0007 — Server-side missed-dose detection (Phase 3)

- Status: accepted
- Date: 2026-10-16 (revised after the PR #12 reviews)
- Scope: TZ §2.5 ("Пропуск … через X минут … пуш близким. Детект пропуска — на сервере"),
  §5 "Фаза 3" (ARQ); backend `missed_dose_alerts`, `detector_state`,
  `app/services/missed_doses.py`, `app/worker.py`
- Related: ADR 0005 (recipients), ADR 0006 §1 (journal locks), ADR 0008 (push delivery),
  ADR 0010 (pending deletion), ADR 0003 §6 (effective mark), ADR 0001 (local reminders),
  `docs/spec/schedule.md`, `docs/spec/dose-state.md` (milestone 3.1), decisions D4, D5

## Context

Reminders are local and fire offline (ADR 0001). Relatives must learn when a dose stays
unmarked X minutes after it was due (default 30, configurable per profile, 5–720). Only the
server sees all devices, so detection runs there on the schedules and dose events it holds.
Occurrences are not stored: the shared engine expands them from rules, and dose events
refer to them by key `{schedule_id}/{YYYY-MM-DD}T{HH:MM}`.

The detector must not double-alert, flood after downtime, alarm for a schedule created
after its own dose time, race with late marks or account deletion, or lose late undos; it
must handle snoozes, time zones and DST without logic of its own.

## Decision

### 1. Shared dose-state semantics

`docs/spec/dose-state.md` (3.1) defines, from an occurrence's dose events: the effective
mark (last non-undone `taken`/`skipped` by `at`, tie on the larger id, ADR 0003 §6); the
latest non-undone snooze (by `at`, tie on the larger id); `due = max(occurrence instant,
latest snooze_until)`; `missed(T, X) ⇔ no mark ∧ T ≥ due + X`. Vectors, a Python reference
and a Dart port in `pillpal_core` run the same cases, so Today and the server agree.

### 2. Tick

ARQ cron `detect_missed_doses`, every 60 s.

1. **One tick at a time:** a session-level `pg_try_advisory_lock(DETECTOR_LOCK_KEY)` held
   for the whole tick; if not acquired, skip. (A row lock would be released by the first
   per-batch commit and let ticks overlap.)
2. Window `[w, e)` from `detector_state.watermark`, `e = min(now, w + 10 min)`; after more
   than 6 h of downtime `w` jumps to `now − 6 h` and the skipped span is logged as a count.
3. Eligible profiles, keyset-paged by id (500): live, not archived (ADR 0005 §5), owner not
   `pending_deletion` (ADR 0010), `missed_alerts_enabled`, and either managed with
   co-guardians or with an active grant having `notify_missed`.
4. **Per batch, one transaction:** `lock_journal(owner_ids)` (sorted) before reading
   anything else, then re-check eligibility under the locks (a deletion request or archive
   that committed first is seen). Candidates:
   - **A** — occurrences of live schedules of live medications with `instant + X ∈ [w, e)`
     (`expand(rule, schedule_id, tz, w − X, e − X)`), dropping occurrences before the
     schedule's `created_at`;
   - **B** — keys of non-undone snoozes with `snooze_until + X ∈ [w, e)`;
   - **C** — keys of `undo` events with `recorded_at ∈ [w, e)`: a late undo of a mark or
     snooze makes an occurrence unmarked or due earlier after its window has passed
     (partial index on `recorded_at WHERE type = 'undo'`).
   Evaluate dose state; alert on keys with no mark whose final `due + X` lies in `[w, e)`
   (A, B) or before `e` (C). Each occurrence is counted once at its final due; a re-snooze
   moves it; C catches what the window already passed.
5. `INSERT … ON CONFLICT (profile_id, occurrence_key) DO NOTHING RETURNING id`; for new
   alerts, one push-outbox row per recipient token (ADR 0008).
6. The watermark moves to `e` in a **separate final transaction**, after every batch has
   committed; then the lock is released and delivery enqueued.

Invalid rules are skipped and logged with `schedule_id` and an error code only (Pydantic
errors would print the rule).

**Recipients:** the owner of a managed profile that has co-guardians; guardians; grantees
of active grants with `notify_missed` created before `due`; for `hidden` medications only
full-access recipients; never the owner of a self profile (local reminders) and never a
`pending_deletion` user. Access is checked again at send time (ADR 0008 §6).

### 3. Late marks resolve, never re-send

`record_dose_event` runs under the owner's journal lock, as does the detector batch. A late
`taken`/`skipped` therefore either commits before the batch reads events (no alert) or sees
the alert (sets `resolved_at` in the same transaction). Recipients of `resolved` are
recomputed by the rule above at resolution time, not read from the outbox (whose rows are
cascaded and purged). An alert is never sent twice.

After a profile's medication is narrowed to `hidden`, a `missed` push already delivered to a
viewer stays on the device, and no `resolved` is sent to that viewer afterwards (it would confirm
that a hidden medication exists). Un-marking an occurrence after its alert was resolved does not
re-alert: the alert row still exists (`ON CONFLICT`).

Lowering `missed_alert_minutes` can skip occurrences whose new `due + X` is already before
`w`; this is accepted and documented.

### 4. Offline policy and the `unconfirmed` variant (D5)

The detector decides at `due + X` on what the server knows and never waits for devices.
For a `self` profile whose owner's devices were all last seen (`devices.last_seen_at`)
before the occurrence instant, the alert is `variant = unconfirmed`. The app renders "no
confirmation; phone last synced around HH:00" using `ScopeOut.owner_last_seen_at`, floored
to the hour (ADR 0006 §2). The time is never in a push payload. Managed profiles are always
`missed`. The owner accepted (D5) that relatives learn the last sync hour; the invite
disclosure screen lists it.

False alarms from marks made in a notification while the app is terminated are reduced by
uploading those marks in the background (3.7).

### 5. Time zones (D4)

- Server: `fixed` → `fixed_tz`; `local` → `profiles.timezone`.
- App: **the user's own self profile uses the device zone** (synced to the server by
  `syncDeviceZone`); **every other scope uses `profiles.timezone`** — managed profiles
  (grandma's 08:00 stays her 08:00 when the guardian travels) and relatives' self profiles
  (their day view matches their zone). This changes Phase 2 behaviour for managed profiles.
- The caller-side rule is noted in `docs/spec/schedule.md` §3.1 in 3.5
  (`schedule-engine-guardian`). DST stays in the engine. Between a device zone change and
  the next sync server instants use the old zone; keys are nominal and still match.

### 6. Worker, logging and load

- `app/worker.py`: crons `detect_missed_doses` (1 min), `deliver_pushes` (10 s),
  `erase_expired_accounts` (hourly, ADR 0010) and `cleanup_retention` (daily). Jobs are
  plain `async def f(ctx, …)`, so ARQ (maintenance mode) can be swapped.
- Every job runs in a wrapper that logs failures with exception type and frames only (the
  HTTP middleware policy), never `str(exc)`: asyncpg errors include parameters, Pydantic
  errors include input. `keep_result=0`; JSON job serializer (no pickle); Redis with
  password/ACL. Log-capture tests cover an invalid rule and a provider connection failure.
- Latency ≤ X + 60 s + delivery. Constant number of queries per batch (statement-counter
  test). Target 10k eligible profiles per tick under 5 s; sharding by
  `hashtext(profile_id) % N` is a follow-up.
- Retention: alerts 72 h (catch-up ≤ 6 h and push staleness 2 h never need more).

## Implementation notes (3.5)

- **Files:** pure rules in `app/domain/missed.py` (windows, `alert_due_at`, `occurrence_instant`,
  variant, recipients); `app/services/missed_doses.py` (tick), `missed_batch.py` (batch),
  `missed_queries.py`, `missed_recipients.py`, `missed_resolution.py`; tables in `app/db/alerts.py`.
  Revisions `0012_missed_dose_alerts` and `0013_dose_events_detector_idx` (the plan's longer name
  exceeded the 32-character `alembic_version` column).
- **One window per tick.** A backlog after downtime is caught up over several ticks (at most ten
  minutes each); the skipped span beyond six hours is logged once as `detector_gap_skipped`
  with `skipped_seconds` (a number only).
- **Lock.** `pg_try_advisory_lock(hashtextextended('pillpal.missed_dose_detector', 0))` on a
  dedicated autocommit connection; if the unlock cannot be confirmed the connection is invalidated,
  which drops the lock. `lock_journal` now takes any number of owner locks in **one statement**
  (an ordered subquery, uuid order, the same order as before), so a batch's statement count does
  not grow with its profiles; `tests/test_missed_timing.py` pins it.
- **Late undo (C) has a horizon.** An undo recorded in the window raises an alert only if the
  occurrence's `due + X` is within `DETECTOR_MAX_CATCHUP_SECONDS` behind the window end:
  undoing last week's mark in the history must not page relatives about last week, and 72 h of
  alert retention then always covers the dedupe.
- **Keys of snoozes and undos are trusted only as far as the rule confirms them**
  (`occurrence_instant`: right schedule, a qualifying day in the course, an existing slot).
  An undo's own key is not consulted: its target's key is.
- **Guardian opt-out.** `notify_missed` is honoured for every grant role. A guardian who muted
  alerts still counts as a co-guardian for the managed owner's alert.
- **Resolution** recomputes recipients with the same function as the alert; it does not look at
  `missed_alerts_enabled` (clearing a notification is harmless), but a profile that is gone, an
  archive, or an owner pending deletion gets nothing.
- **`m` in the payload** for `anonymous` medications: see ADR 0008 ("FCM `m` for `anonymous`
  medications").
- **Review fixes (PR #18).** The dose-state fold runs **per profile** (a key is client text and
  can occur in another profile's events; the write path deliberately gives the same answer for a
  key of an unknown and of a foreign schedule, so there is no existence oracle). The send-time check of `missed` and
  `resolved` joins the alert's medication: projected roles need `shared` when the payload names the
  medication and anything but `hidden` otherwise, and `missed` needs `notify_missed`.
  `lock_journal` calls the SQL function `lock_journal_owners(text[])` (migration 0013), which takes
  the advisory locks in hash-key order inside a loop over a sorted query (guaranteed order).
  Batches run under `SET LOCAL lock_timeout` (`DETECTOR_LOCK_TIMEOUT_MS`): a timeout fails the tick
  and the window replays. A batch holds one advisory lock per owner, so `DETECTOR_PROFILE_BATCH`
  is capped at 1000 and PostgreSQL's `max_locks_per_transaction` (default 64, the lock table is
  shared by `max_connections`) must leave room for it: raise it for large batches. Profiles whose
  owner changed between the page and the lock (a D1 hand-over) are redone under their new owners'
  locks. Undos are read `DETECTOR_SKEW_MARGIN_SECONDS` (120) before the window because
  `recorded_at` is the writer's clock. The index migration builds indexes `CONCURRENTLY`.
  A managed owner has no personal opt-out (they hold no grant to mute). **The detector is off by
  default (`DETECTOR_ENABLED=false`) and must not be enabled in production before milestone 3.6**:
  until the app plans managed and foreign profiles in `profiles.timezone` and syncs its own zone
  (D4), the server would alert on instants the apps do not remind at. Consecutive failed ticks are
  logged as `consecutive_failures`.
- **Statements per batch** are constant (16 for a tick with one page, whatever the number of
  profiles or alerts); arrays are bound as one parameter.

## Consequences

- New tables `missed_dose_alerts` and `detector_state`; partial indexes on snoozed and undo
  events; `profiles.missed_alert_minutes` and `missed_alerts_enabled`.
- The detector briefly holds owners' journal locks per batch; writers of those owners wait
  for at most one batch.
- Archived profiles and accounts pending deletion produce no alerts, and a deletion request
  committed during a tick is seen under the locks.

## Alternatives considered

- **Per-occurrence delayed jobs:** millions of jobs, cancelled and re-created on every edit
  or snooze.
- **Materialized occurrences:** duplicates the engine and must be rewritten on every edit
  and zone change.
- **Wait for device confirmation:** suppresses the alarms that matter.
- **`FOR UPDATE NOWAIT` on the watermark row** (first draft): released by per-batch commits.
- **Device zone for managed profiles** (Phase 2 behaviour): a travelling guardian would
  shift grandma's reminders away from what the server detects.
