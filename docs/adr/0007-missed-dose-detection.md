# ADR 0007 — Server-side missed-dose detection (Phase 3)

- Status: accepted
- Date: 2026-10-16
- Scope: TZ §2.5 ("Пропуск … через X минут … пуш близким. Детект пропуска — на сервере"),
  §5 "Фаза 3" (ARQ); backend `missed_dose_alerts`, `detector_state`,
  `app/services/missed_doses.py`, `app/worker.py`
- Related: ADR 0005 (recipients), ADR 0008 (push delivery), ADR 0010 (pending deletion),
  ADR 0003 §6 (effective mark), ADR 0001 (local reminders), `docs/spec/schedule.md`,
  `docs/spec/dose-state.md` (milestone 3.1), owner decisions D4 and D5

## Context

Reminders are local and fire offline (ADR 0001). Relatives must learn when a dose stays
unmarked X minutes after it was due (default 30, configurable). Only the server sees all
devices, so detection runs there, on the schedules and dose events it holds. The server
does not store occurrences: it expands them from rules with the shared engine, and dose
events refer to occurrences by key `{schedule_id}/{YYYY-MM-DD}T{HH:MM}`.

The detector must not double-alert after a restart, must not flood after downtime, must
not alarm for a schedule created after its own dose time, and must handle snoozes, undo,
time zones and DST without logic of its own.

## Decision

### 1. Shared dose-state semantics

`docs/spec/dose-state.md` (3.1) defines, from an occurrence's dose events:

- the effective mark (ADR 0003 §6: last non-undone `taken`/`skipped` by `at`, tie on the
  larger id);
- the latest non-undone snooze;
- `due = max(occurrence instant, latest snooze_until)`;
- `missed(T, X) ⇔ no mark ∧ T ≥ due + X`.

They become vectors (`spec/dose-state-vectors/`), a Python reference
(`app/domain/dose_state.py`) and a Dart port in `pillpal_core`, both running every vector.
The app's Today screen and the server agree by construction.

### 2. Windowed, stateless tick

An ARQ cron `detect_missed_doses` runs every 60 s (`unique=True`).

1. Lock `detector_state('missed_dose')` with `FOR UPDATE NOWAIT`; if locked, another
   worker is ticking: skip. Window `[w, e)`, `e = min(now, w + 10 min)`. After downtime
   longer than 6 h, `w` jumps to `now − 6 h` and the skipped span is logged as a count.
2. Eligible profiles, keyset-paged by id (500 per batch): live, **not archived** (ADR 0005
   §5), owner **not in `pending_deletion`** (ADR 0010), `missed_alerts_enabled`, and either
   managed or with at least one active grant with `notify_missed`.
3. Candidates: occurrences of live schedules of live medications with
   `instant + X ∈ [w, e)` (engine `expand`), dropping occurrences before the schedule's
   `created_at`; plus keys of non-undone snoozes with `snooze_until + X ∈ [w, e)`.
4. Evaluate dose state for the candidates' events; keep unmarked keys whose **final**
   `due + X` lies in the window. Each occurrence is therefore evaluated exactly once, at
   its final due time; a re-snooze moves it again.
5. `INSERT … ON CONFLICT (profile_id, occurrence_key) DO NOTHING RETURNING id`: the UNIQUE
   constraint is the "one alert per occurrence" guarantee. For new alerts, insert one
   push-outbox row per recipient token (ADR 0008).
6. Advance the watermark to `e` in the same transaction and enqueue delivery.

Recipients: the owner of a managed profile; guardians; grantees of active grants with
`notify_missed` whose grant was created before `due`. For `hidden` medications, only
full-access recipients (owner of a managed profile, guardians). Never the owner of a self
profile (they have local reminders) and never a user in `pending_deletion`.

### 3. Late marks resolve, never re-send

A `taken`/`skipped` recorded later for an alerted occurrence (sync push or REST, same
transaction as the event) sets `resolved_at` and sends `resolved` to the recipients of the
`missed` push, which replaces the alarm on their devices (same notification tag). An alert
is never sent twice.

### 4. Offline policy and the `unconfirmed` variant (D5)

The detector decides at `due + X` on what the server knows. It never waits for devices:
"the phone is off" is exactly when relatives need to know. To separate "forgot" from
"phone off", for a `self` profile whose owner's devices were all last seen
(`devices.last_seen_at`, touched by push, refresh and scoped pull) before the occurrence
instant, the alert is `variant = unconfirmed`, rendered as "no confirmation, phone not
synced since …". Otherwise it is `missed` ("dose not marked"). Managed profiles are always
`missed`. The owner accepted (D5) that relatives learn the last sync time; it reveals no
medical data.

False alarms from marks made in a notification while the app is terminated are reduced by
uploading those marks in the background (milestone 3.7, ADR 0001 addendum).

### 5. Time zones (D4)

- `fixed` medications use `fixed_tz`.
- `local` medications use `profiles.timezone`.
- **`self` profiles:** the app keeps `profiles.timezone` equal to the device zone (3.6), so
  the server follows the person.
- **Managed profiles keep their own zone.** Guardians' devices plan the managed profile's
  `local` medications in the profile's zone, not the device's: grandma's 08:00 stays her
  08:00 when the guardian travels. This changes Phase 2 behaviour for managed profiles and
  matches what the server detects.
- DST is handled by the engine (`docs/spec/schedule.md` §3.1). Keys are nominal, so a zone
  change between a device and the next sync shifts instants but not keys (known, bounded
  limitation).

### 6. Worker and load bounds

- ARQ worker (`app/worker.py`), same image, own compose service; crons
  `detect_missed_doses` (1 min), `deliver_pushes` (10 s), `erase_expired_accounts` (hourly,
  ADR 0010) and `cleanup_retention` (daily). Job functions are plain `async def f(ctx, …)`
  so ARQ, which is in maintenance mode, can be swapped.
- Latency ≤ X + 60 s + delivery.
- Constant number of queries per profile batch (asserted by a statement-counter test).
- Target: 10k eligible profiles per tick in under 5 s on one worker; beyond that, shard by
  `hashtext(profile_id) % N` (follow-up).
- Retention: alerts 30 days.

## Consequences

- New tables `missed_dose_alerts` and `detector_state`, a partial index on snoozed events;
  `profiles` gains `missed_alert_minutes` (5–720, default 30) and `missed_alerts_enabled`.
- The detector never writes dose events and never changes what devices show; it only
  creates alerts and pushes.
- Detector logs carry ids, counts and codes only; a log-capture test asserts no medication
  name or occurrence key appears.
- Archived profiles and accounts pending deletion produce no alerts, so a deletion request
  stops all monitoring at once.

## Alternatives considered

- **Per-occurrence delayed jobs** (enqueue at dose time + X): millions of scheduled jobs,
  and every schedule edit or snooze would have to cancel and re-create them.
- **Materialized occurrences table:** duplicates the engine's output and must be rewritten
  on every schedule edit and zone change.
- **Wait for device confirmation before alerting:** suppresses exactly the alarms that
  matter (phone off, person unwell).
- **Device zone for managed profiles** (Phase 2 behaviour): a travelling guardian would
  shift grandma's reminders, and the server would alert at a different time than the
  guardian's phone reminds.
