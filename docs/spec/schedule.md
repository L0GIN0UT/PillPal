# Schedule engine — formal specification (rule v1)

Status: normative. Source requirements: `docs/TZ.md` §2.2 and §4.2.

The schedule engine turns a **schedule rule** (a small JSON document stored in
`schedules.rule`) into a deterministic list of **occurrences** for a time
window. It is implemented twice:

| Implementation | Location | Used by |
|---|---|---|
| Python (reference) | `backend/app/domain/schedule/` | server: validation of `rule`, missed-dose detection |
| Dart | `packages/pillpal_core/` | mobile client: offline reminders, "Today" screen |

Both implementations MUST produce identical results. This is enforced by the
shared test vectors in `spec/schedule-vectors/` (see its `README.md`), which
both test suites execute. Any change to this document requires matching
changes to the vectors and to both implementations in the same pull request.

The key words MUST, MUST NOT, SHOULD are used as in RFC 2119.

---

## 1. Rule document (version 1)

```json
{
  "v": 1,
  "kind": "weekdays",
  "start_date": "2026-10-16",
  "end_date": null,
  "weekdays": [1, 3, 5],
  "times": [
    {"time": "08:00", "dose": {"amount": "1", "unit": "tablet"}},
    {"time": "20:00", "dose": {"amount": "0.5", "unit": "tablet"}}
  ]
}
```

### 1.1 Fields

| Field | Type | Required | Constraint |
|---|---|---|---|
| `v` | JSON integer | yes | exactly `1` |
| `kind` | string | yes | one of `daily`, `weekdays`, `interval_days`, `as_needed` |
| `start_date` | string | yes | local date, see §1.2 |
| `end_date` | string or `null` | no (absent = `null`) | local date, `end_date >= start_date`; `null` = open-ended |
| `weekdays` | array of integers | iff `kind = weekdays` | non-empty, each `1..7` (ISO: Monday = 1 … Sunday = 7), no duplicates |
| `interval_days` | integer | iff `kind = interval_days` | `2 <= interval_days <= 366` |
| `times` | array of time slots | yes | see §1.3 |

Validation rules (a rule violating any of them is **invalid**; the Python
implementation raises `pydantic.ValidationError`, the Dart implementation
throws `RuleValidationError`). Every rule in `spec/schedule-vectors/invalid.json`
MUST be rejected:

1. The document MUST be a JSON object. Unknown keys are rejected at every
   level (rule, time slot, dose).
2. "JSON integer" means an integer number token. Booleans (`true`), floats
   (`1.0`) and strings (`"1"`) are rejected wherever an integer is expected.
   Strings are never coerced from other types and vice versa.
3. `weekdays` MUST be absent or `null` unless `kind = weekdays`;
   `interval_days` MUST be absent or `null` unless `kind = interval_days`.
4. For `kind = weekdays`, `weekdays` MUST be present and non-null; likewise
   `interval_days` for `kind = interval_days`.
5. `weekdays` is normalised to ascending order (`[5, 1]` → `[1, 5]`).

### 1.2 Dates

A date is a string matching `^[0-9]{4}-[0-9]{2}-[0-9]{2}$` that denotes a valid
proleptic-Gregorian calendar date with year in `2000..2199`
(`"2027-02-29"` is invalid, `"2028-02-29"` is valid, `"2026-1-5"` is invalid).
Dates are **local calendar dates** in the effective time zone (§3), not UTC
dates.

### 1.3 Time slots

```json
{"time": "08:00", "dose": {"amount": "0.5", "unit": "tablet"}}
```

| Field | Constraint |
|---|---|
| `time` | string matching `^([01][0-9]|2[0-3]):[0-5][0-9]$` (`00:00`..`23:59`) |
| `dose.amount` | string, see below |
| `dose.unit` | string, one of the units in §1.4 |

- For `kind = as_needed`, `times` MUST be an empty array.
- Otherwise `times` MUST contain 1..24 slots with pairwise distinct `time`
  values. Slots are normalised to ascending `time` order.
- Each slot has its own dose, so "different doses at different times" is a
  single rule. "Different doses on different days" is expressed as several
  schedules (rules) attached to one medication.

**Dose amount** is a decimal string matching
`^(0|[1-9][0-9]{0,5})(\.[0-9]{1,3})?$` (no sign, no exponent, no leading
zeros, at most 6 integer and 3 fractional digits, `.5` and `5.` are invalid),
whose value is strictly greater than zero (`"0"`, `"0.000"` are invalid).
It is normalised by removing trailing zeros of the fractional part and then a
trailing `.` (`"0.50"` → `"0.5"`, `"2.000"` → `"2"`). Amounts are strings so
that `0.1 + 0.2`-style binary floating point never touches doses.

### 1.4 Dose units

Fixed enumeration (stable identifiers; UI translates them):

| Unit | Meaning |
|---|---|
| `tablet` | tablet / pill |
| `capsule` | capsule |
| `ml` | millilitre |
| `mg` | milligram |
| `drop` | drop |
| `puff` | inhaler puff |
| `sachet` | sachet / powder packet |
| `unit` | unit (e.g. insulin IU) |
| `injection` | injection |
| `other` | anything else (described in medication notes) |

Units are case-sensitive (`"Tablet"` is invalid).
Adding a unit is a backwards-compatible change for readers that are updated
first (server, then clients); it MUST be accompanied by a vector.

### 1.5 Canonical form

The canonical JSON of a valid rule contains `v`, `kind`, `start_date`,
`end_date` (possibly `null`), `times` (sorted, amounts normalised), plus
`weekdays` (sorted) only for `kind = weekdays` and `interval_days` only for
`kind = interval_days`. Validation of a canonical document yields the same
canonical document (idempotent).

---

## 2. Qualifying local dates

Let `D` be a local calendar date. `D` **qualifies** for a rule iff

1. `start_date <= D`, and
2. `end_date` is `null` or `D <= end_date` (**course bounds are inclusive**), and
3. depending on `kind`:
   - `daily`: always;
   - `weekdays`: `isoWeekday(D) ∈ weekdays` (Monday = 1 … Sunday = 7);
   - `interval_days` with `n = interval_days`:
     `days(D − start_date) mod n = 0`, where `days` counts calendar days
     (the anchor is `start_date`; a 23- or 25-hour DST day is still one day);
   - `as_needed`: never (as-needed medications have no occurrences; only
     manual dose events are recorded).

## 3. Occurrences

For every qualifying date `D` and every slot `s` of `times` there is exactly
one **nominal occurrence** `(D, s.time)` with:

| Field | Value |
|---|---|
| `key` | `"{schedule_id}/{YYYY-MM-DD}T{HH:MM}"` built from the *nominal* `D` and `s.time` |
| `local_date` | `D` (nominal) |
| `local_time` | `s.time` (nominal, `"HH:MM"`) |
| `at_utc` | the instant of §3.1 |
| `dose_amount` | `s.dose.amount` (normalised, §1.3) |
| `dose_unit` | `s.dose.unit` |

Example key: `"7f1c…e2/2026-10-16T08:00"`. Dose events reference occurrences by
key, so client and server compute it independently. The key never changes
because of time zone or DST effects: it is always the rule's nominal local
date and time, even when the instant is shifted (§3.1).

### 3.1 Local time → instant

The **effective time zone** `Z` is an IANA zone name resolved by the caller
(`tz_mode = local` → the user's current device/profile zone; `tz_mode = fixed`
→ `medications.fixed_tz`). The engine does not know about `tz_mode`.

Let `T` be the wall-clock reading `D s.time:00` and `offset(u)` the UTC offset
of `Z` at instant `u`. The set of instants that display `T` in `Z` is
`I(T) = { u : u + offset(u) = T }`.

- **Normal time** — `I(T)` has one element; that is the instant.
- **Ambiguous time** (clocks fall back, `I(T)` has two elements) — the
  **earlier** instant is used ("first occurrence"; the offset in effect before
  the transition).
- **Non-existent time** (clocks spring forward, `I(T)` is empty) — the wall
  time is interpreted with the offset in effect **before** the transition:
  `u = T − offset_before`. On the wall clock this is `T` shifted forward by the
  length of the gap.

In one sentence: **instant = `T − offset_before`**, where `offset_before` is
the UTC offset in effect before the transition that makes `T` ambiguous or
non-existent (for a normal time simply the offset at `T`). This is exactly
Python `zoneinfo` behaviour for `datetime(..., fold=0)` (PEP 495): for a
non-existent time `utcoffset()` returns the pre-transition offset, so 02:30 in
Berlin's 02:00→03:00 gap becomes 01:30Z, which the clock shows as 03:30 CEST.
Examples (all covered by vectors in `dst.json`):

| Zone | Nominal local time | Situation | Instant (UTC) | Wall clock after |
|---|---|---|---|---|
| Europe/Berlin | 2026-03-29 02:30 | gap 02:00→03:00 | 2026-03-29T01:30Z | 03:30 CEST |
| Europe/Berlin | 2025-10-26 02:30 | overlap 03:00→02:00 | 2025-10-26T00:30Z | 02:30 CEST (first) |
| America/New_York | 2026-03-08 02:15 | gap 02:00→03:00 | 2026-03-08T07:15Z | 03:15 EDT |
| America/New_York | 2025-11-02 01:30 | overlap 02:00→01:00 | 2025-11-02T05:30Z | 01:30 EDT (first) |
| Australia/Lord_Howe | 2025-10-05 02:15 | 30-min gap 02:00→02:30 | 2025-10-04T15:45Z | 02:45 +11 |
| Pacific/Apia | 2011-12-30 08:00 | whole day skipped (−10 → +14) | 2011-12-30T18:00Z | 2011-12-31 08:00 +14 |

Consequently two different keys can map to the same instant (Berlin 02:30 and
03:30 on 2026-03-29; Apia 2011-12-30 08:00 and 2011-12-31 08:00). Both
occurrences exist; they are distinct reminders with distinct keys.

**Portable algorithm** (used by the Dart implementation, whose `timezone`
package only offers `offset(u)`). It was cross-checked against `zoneinfo`
fold=0 for every IANA zone of the system database (498 zones), every offset
transition 2000–2040 (14 482 transitions), at every 15-minute wall time from
30 h before to 54 h after each transition (4.87 M wall times, 0 mismatches);
`backend/tests/domain/schedule/test_expand.py` re-runs this check for a set of
tricky zones on every CI run. The same algorithm, run in Python on the
database embedded in `package:timezone` (decoded from `latest_all.dart`),
reproduces every valid vector and agrees with `zoneinfo` for 2000–2037 except
in zones whose rules differ between the two tzdata releases (Morocco, British
Columbia/Alberta, Moldova):

```
oBefore = offset(T − 24h)       # T treated as if it were a UTC instant
oAfter  = offset(T + 24h)
candidates = [T − oBefore, T − oAfter]  filtered by offset(u) == T − u
if candidates non-empty: return min(candidates)
else:                    return T − oBefore      # gap
```

It assumes at most one offset transition within ±24 h of `T` — true for every
zone in tzdata for the supported date range.

**Resolving `local` is the caller's job (Phase 3, decision D4).** The engine takes `Z` as
given; this note records which zone each caller passes for a `tz_mode = local` medication, so
the server's detector (`backend/app/services/missed_doses.py`) and the apps expand the same
instants for the same profile:

| Caller | `tz_mode = fixed` | `tz_mode = local` |
|---|---|---|
| Server (missed-dose detector, any profile) | `medications.fixed_tz` | `profiles.timezone` of the medication's profile |
| App, the signed-in user's **own self profile** | `fixed_tz` | the **device** zone (kept in `profiles.timezone` by the app's `syncDeviceZone`) |
| App, **every other scope** (managed profiles, relatives' self profiles) | `fixed_tz` | `profiles.timezone` of that profile |

So a managed profile's "08:00" stays the managed person's 08:00 when the guardian travels, and a
relative's day view matches the relative's own zone. This is a change of Phase 2 behaviour for
managed profiles (the device zone was used for them). Between a device zone change and the next
sync the server still holds the old zone; occurrence keys are nominal (§3), so keys written
meanwhile still match, only the server's instants lag. Nothing here changes the engine, the
rule, the keys or the vectors.

### 3.2 Unknown zone

An unknown IANA name is a caller error (Python: `ValueError`; Dart:
`ArgumentError`). Names are case-sensitive. `"UTC"` MUST be supported.

## 4. Expansion

```
expand(rule, schedule_id, tz, start, end) -> [Occurrence]
```

- Returns every occurrence (§3) whose instant satisfies
  `start <= at_utc < end` (**half-open window**; an occurrence exactly at
  `start` is included, exactly at `end` is excluded).
- `start`, `end` are absolute instants (Python: timezone-aware `datetime` in
  any zone, naive is a `ValueError`; Dart: any `DateTime`, compared as
  instants). The 400-day limit applies to elapsed real time.
- `end < start` → error (`ValueError` / `ArgumentError`); `end == start` → `[]`.
- `end − start > 400 days` → error. Callers needing more MUST page.
- `schedule_id` MUST be a non-empty string (error otherwise). It is opaque to
  the engine. Callers (server and app) MUST pass the canonical lowercase UUID
  string of the schedule, so keys computed on different devices are identical;
  the server rejects non-canonical ids instead of normalizing them.
- Result order: ascending by `at_utc`, ties broken by `key` (ordinal string
  comparison; keys within one call differ only in ASCII digits).
- Window membership is decided on the instant, not on the nominal date: an
  occurrence whose nominal date is outside the local dates of the window but
  whose (shifted) instant is inside it IS returned, and vice versa.

Implementation note: both implementations iterate local dates from
`localDate(start) − 2 days` to `localDate(end) + 2 days`, intersected with the
course bounds, which is sufficient because a DST shift never exceeds 24 h.
Cost is O(days × slots) ≤ ~405 × 24 offset look-ups.

## 5. Out of scope for v1

Cycles (21 on / 7 off), titration, "every N hours", per-occurrence overrides,
skipping holidays. A future rule version gets a new `v` value; readers MUST
reject versions they do not know.

## 6. Time zone data

Python uses the system IANA database or the `tzdata` package; Dart uses the
`timezone` package's embedded `latest_all` database. Releases may lag one
another, so instants for zones whose rules changed recently can differ between
server and client until both are updated. Keys never differ. Vectors therefore
avoid zones with rule changes after 2024 (e.g. Canadian zones, Morocco,
Moldova).

The Dart database lists explicit transitions only up to 2037, while `zoneinfo`
extrapolates DST rules indefinitely. Instants for dates after 2037-12-31 in DST
zones are therefore **not guaranteed** to agree between implementations
(keys still agree). Vectors use dates ≤ 2037 (enforced by
`spec/validate_vectors.py`).

## 7. Implementations and API

Both implementations expose the same concepts with idiomatic names.

| Concept | Python (`app.domain.schedule`) | Dart (`package:pillpal_core`) |
|---|---|---|
| Rule | `ScheduleRule.model_validate(dict)` (pydantic v2, frozen, `extra="forbid"`); `rule.to_json()` → canonical dict | `ScheduleRule.fromJson(Object?)`; `rule.toJson()` → canonical map |
| Invalid rule | `pydantic.ValidationError` | `RuleValidationError` (`implements Exception`) |
| Local date | `datetime.date` (dates in the rule may also be passed as `date` objects) | `LocalDate` (value type, `toString()` = `YYYY-MM-DD`) |
| Occurrence | frozen dataclass `Occurrence(key, local_date, local_time, at_utc, dose_amount, dose_unit)` | `Occurrence(key, localDate, localTime, atUtc, doseAmount, doseUnit)` |
| Expansion | `expand(rule, *, schedule_id, tz, start, end) -> list[Occurrence]` | `expand(rule, scheduleId:, tz:, start:, end:) -> List<Occurrence>` |
| Key | `occurrence_key(schedule_id, local_date, local_time)` | `occurrenceKey(scheduleId, localDate, localTime)` |
| Caller errors | `ValueError` | `ArgumentError` |

`at_utc` / `atUtc` is always in UTC (Python: `tzinfo=UTC`; Dart:
`isUtc == true`). The Dart package loads the `latest_all` database of
`package:timezone` lazily on first use (`ensureTimeZonesInitialized()` lets
the app do it at start-up) and obtains offsets only through
`Location.translate(ms) - ms`, which is an `int` in every supported version of
the package (`TimeZone.offset` changed from `int` to `Duration` in 0.11).
If the app has already initialized the database itself (e.g. before
`setLocalLocation` for notifications), the engine does not re-initialize it,
because that would reset `tz.local` to UTC. The app MUST load `latest_all`:
smaller variants such as `latest_10y` lack the history the vectors need.

## 8. Test vectors

`spec/schedule-vectors/` holds the shared vectors; their format is described
in its `README.md` and `schema.json`. Each valid case gives a rule, a
`schedule_id`, a zone and a window and lists the exact expected occurrences
(order included); each invalid case gives a rule that MUST be rejected. Both
test suites run every file; `python spec/validate_vectors.py` checks the files
themselves in CI.
