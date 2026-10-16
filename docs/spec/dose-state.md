# Dose state — formal specification (v1)

Status: normative. Source requirements: `docs/TZ.md` §2.4 (dose events are
append-only) and §2.5 (a missed dose is detected on the server, relatives are
told after X minutes). The mark rule is decided in
`docs/adr/0003-schedule-edits-and-history.md` §6; this document makes it, and
the rules around it, an executable contract.

The **dose state** of an occurrence is what its dose events say about it:
whether it is marked (`taken` / `skipped`), until when it is snoozed, when it
is due, and whether it is missed at a given instant. It is implemented twice:

| Implementation | Location | Used by |
|---|---|---|
| Python (reference) | `backend/app/domain/dose_state.py` | server: missed-dose detector (Phase 3, milestone 3.5) |
| Dart | `packages/pillpal_core/lib/src/doses/` | mobile client: Today screen, history, stock, reminder inputs |

Both implementations MUST produce identical results. This is enforced by the
shared vectors in `spec/dose-state-vectors/` (see its `README.md`), which both
test suites execute. Any change to this document requires matching changes to
the vectors and to both implementations in the same pull request (same rule as
`docs/spec/schedule.md`).

The key words MUST, MUST NOT, SHOULD are used as in RFC 2119.

---

## 1. Inputs

### 1.1 Occurrence

An occurrence is identified by its **occurrence key**
`{schedule_id}/{YYYY-MM-DD}T{HH:MM}` (nominal local date and time, never
DST-shifted; `docs/spec/schedule.md` §3). Its **occurrence instant** is the
`at_utc` the schedule engine computes for it. The dose-state functions never
expand schedules: the caller supplies the key and, where needed, the instant.

Keys are compared as opaque strings (exact equality). Events without an
occurrence key (as-needed intakes) belong to no occurrence and are outside
this contract.

### 1.2 Dose event

| Field | Type | Meaning |
|---|---|---|
| `id` | string | Unique id (client-generated UUID in practice, lowercase). Compared as a string, code unit by code unit; for lowercase canonical UUIDs this equals numeric order. |
| `type` | `taken` \| `skipped` \| `snoozed` \| `undo` | TZ §2.4. |
| `at` | instant | When it happened (client clock), microsecond precision, UTC. |
| `occurrence_key` | string or null | The occurrence it refers to. |
| `target_event_id` | string or null | Only for `undo`: the event it cancels. |
| `snooze_until` | instant or null | Only for `snoozed`: when the dose is due again. |

The write paths guarantee: `target_event_id` is present exactly for `undo`
and names a non-`undo` event of the same medication; `snooze_until` is present
exactly for `snoozed`, after `at` and at most 24 hours later. The fold below
does not rely on these guarantees (data may arrive through sync from an older
client) and defines a result for every input; the vectors pin the unusual
cases.

Instants are timezone-aware. Python: `datetime` with a `tzinfo` (naive values
are rejected with `ValueError`). Dart: `DateTime` compared as instants.

### 1.3 Event set

The functions take the events as an unordered collection: the result MUST NOT
depend on the order of the input, only on the events themselves. The events
are the ones the caller knows; the contract does not filter by the evaluation
instant (§6).

---

## 2. Cancelled events

The **cancelled set** is the set of `target_event_id` of every `undo` event in
the input (`undo` events without a target contribute nothing).

- An `undo` applies by `target_event_id` only. Its own `occurrence_key`
  (normally the target's; null in legacy data) and its own `at` are not
  consulted: an `undo` whose `at` is earlier than its target's still cancels
  it (device clock skew), and an `undo` of an unknown id cancels nothing.
- An `undo` is **never itself cancelled**. An `undo` that targets another
  `undo` is ignored as a correction: the targeted `undo` stays in force
  (ADR 0003 §6: "an undo of an event that is already undone is a no-op"). No
  write path can create it; the rule only fixes how such data folds.
- Marking again after an `undo` is a new event with a new id; the cancelled
  one stays cancelled.

The cancelled set is computed over **all** events of the input, whatever their
occurrence keys, and applied to the events of the occurrence in question.

---

## 3. Effective mark

Among the events of the occurrence with `type` `taken` or `skipped` that are
not in the cancelled set, the **effective mark** is the one with the greatest
`at`; if several share the greatest `at`, the one with the greatest `id`
(ADR 0003 §6: every device picks the same event whatever order sync delivered
them in). If there is none, the occurrence is **unmarked**.

The mark is reported as `(event id, type, at)`. `snoozed` events never mark.

## 4. Snooze

Among the events of the occurrence with `type` `snoozed` and a non-null
`snooze_until` that are not in the cancelled set, the **latest snooze** is the
one with the greatest `at`, ties by the greatest `id`. `snooze_until` of the
occurrence is that event's `snooze_until`, or *none*.

The latest snooze is chosen by `at`, not by the largest `snooze_until`: a later
snooze to an earlier time replaces an earlier snooze to a later time. A snooze
is reported even when the occurrence is marked; a consumer that only wants
live snoozes (the reminder planner) ignores marked occurrences itself
(`docs/spec/reminders.md` §3).

A `snoozed` event without `snooze_until` is ignored (the write paths reject
it).

## 5. Due and missed

```
due(occurrence)   = max(occurrence instant, snooze_until)      # snooze_until = none -> occurrence instant
missed(now, X)    = unmarked  and  now >= due + X
```

- `X` is a non-negative whole number of minutes (the owner-configurable grace
  of TZ §2.5; the default of 30 is a setting, not part of this contract).
- A snooze whose `snooze_until` is before the occurrence instant does not move
  `due` earlier.
- The comparison is inclusive and exact to the microsecond: at
  `due + X - 1 µs` the occurrence is not missed, at `due + X` it is.
- A marked occurrence (`taken` or `skipped`) is never missed, whenever the
  mark was recorded.
- Undoing the mark makes the occurrence unmarked again; undoing the latest
  snooze falls back to the previous one (§4).

## 6. Evaluation context

The functions are pure folds of the events given. They do not read a clock and
do not drop events whose `at` or `recorded_at` is after `now`. A caller that
evaluates an instant in the past MUST pass only the events known at that
instant. The server's detector evaluates with the current time and the stored
events, so an occurrence marked late (after `due + X`) is simply no longer
missed once the mark is stored.

Events of other occurrence keys are ignored (except `undo` events, §2). Grouping
many occurrences at once is the same fold per key over the shared cancelled
set.

---

## 7. Implementations and API

| Concept | Python (`app.domain.dose_state`) | Dart (`package:pillpal_core`) |
|---|---|---|
| Event | frozen dataclass `DoseEvent(id, type, at, occurrence_key, target_event_id, snooze_until)` | `DoseEvent(id:, type:, at:, occurrenceKey:, targetEventId:, snoozeUntil:)` |
| Event type | `Literal["taken", "skipped", "snoozed", "undo"]` | `enum DoseEventType` (`wire` = the name above) |
| Mark | `DoseMark(event_id, type, at)` | `DoseMark(eventId:, type:, at:)` |
| State of one occurrence | `OccurrenceState(mark, snooze_until)` | `OccurrenceState(mark:, snoozeUntil:)` |
| Fold of one occurrence's events | `summarize_events(events)` | `summarizeEvents(events)` |
| One key out of mixed events | `occurrence_state(events, occurrence_key)` | `occurrenceStateOf(events, occurrenceKey)` |
| Every key at once | `occurrence_states_by_key(events)` | `occurrenceStatesByKey(events)` |
| Due | `state.due_at(occurrence_at)` | `state.dueAt(occurrenceAt)` |
| Missed | `state.is_missed(occurrence_at=, now=, grace=)` | `state.isMissed(occurrenceAt:, now:, grace:)` |

`summarize_events` / `summarizeEvents` treat every event they are given as
belonging to one occurrence (the caller has grouped them; `occurrence_key` is
not consulted). `occurrence_states_by_key` / `occurrenceStatesByKey` return an
entry for each key that has a live mark or a live snooze; unmarked keys
without a snooze have no entry. `grace` is a `timedelta` / `Duration`
(non-negative).

## 8. Test vectors

`spec/dose-state-vectors/` holds the shared vectors (format in its
`README.md` and `schema.json`). Each case gives an occurrence key and instant
and a set of events, and lists the expected mark, `snooze_until` and `due`;
optional `missed` probes give `(now, grace_minutes) -> bool`. Both test suites
run every file; `python spec/validate_vectors.py` checks the files themselves
(shape, and that the hand-derived `due` and `missed` values agree with each
other) in CI.
