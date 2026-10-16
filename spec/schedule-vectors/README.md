# Schedule engine test vectors

Shared, language-neutral test cases for the schedule engine specified in
[`docs/spec/schedule.md`](../../docs/spec/schedule.md). The **same files** are
executed by both implementations:

| Implementation | Test that runs every vector |
|---|---|
| Python (`backend/app/domain/schedule`) | `backend/tests/domain/schedule/test_vectors.py` |
| Dart (`packages/pillpal_core`) | `packages/pillpal_core/test/vectors_test.dart` |

CI additionally runs `python spec/validate_vectors.py` (stdlib only) from the
repository root, which checks the structure and internal consistency of the
files (shape per [`schema.json`](schema.json), unique names, key format,
`at_utc` inside the window, ordering, doses matching rule slots, ≥ 30 cases).

## Files

| File | Covers |
|---|---|
| `daily.json` | several times per day with different doses, slot sorting, amount normalisation, exact `[from, to)` boundaries, empty window, year boundary, leap day |
| `weekdays.json` | ISO weekdays, month boundary, weekday taken from the *local* date |
| `interval.json` | `interval_days` anchored at `start_date`, window starting mid-cycle, leap day, year boundary, 366, calendar days across DST |
| `course.json` | inclusive `start_date`/`end_date` in local dates, combined with every kind |
| `as_needed.json` | no occurrences; the maximum 400-day window |
| `dst.json` | gaps and overlaps in Europe/Berlin, America/New_York, Australia/Sydney, Australia/Lord_Howe (30-min), Pacific/Apia (skipped day, 2011) |
| `timezones.json` | Europe/Samara, Asia/Kolkata (+05:30), Asia/Kathmandu (+05:45), Pacific/Kiritimati (+14), Pacific/Pago_Pago (−11), same rule in two zones |
| `invalid.json` | rules that MUST fail validation |

## Case format

Valid case (every file except `invalid.json`):

```json
{
  "name": "dst_berlin_spring_gap_0230_daily",
  "description": "optional, explains the hand derivation",
  "schedule_id": "sched-t01",
  "rule": { "v": 1, "kind": "daily", "start_date": "2026-03-01", "times": [ ... ] },
  "tz": "Europe/Berlin",
  "window": { "from": "2026-03-28T00:00:00Z", "to": "2026-03-31T00:00:00Z" },
  "expected": [
    { "key": "sched-t01/2026-03-29T02:30", "at_utc": "2026-03-29T01:30:00Z",
      "dose_amount": "1", "dose_unit": "tablet" }
  ]
}
```

A runner MUST: validate `rule`; call `expand(rule, schedule_id, tz, from, to)`;
and assert that the result equals `expected` **exactly, including order**
(`at_utc` formatted as `YYYY-MM-DDTHH:MM:SSZ` in UTC).

Invalid case (`invalid.json`): `{"name", "description"?, "rule", "error": true}`.
A runner MUST assert that validating `rule` fails.

## Rules for adding vectors

1. Derive `expected` **by hand** from the spec (write the reasoning into
   `description`, especially for DST), then run both suites. Never paste
   engine output as the expected value without checking it.
2. Names are unique across all files (`^[a-z0-9_]+$`).
3. Use dates ≤ 2037 (the Dart `timezone` database has no transitions after
   2037) and avoid zones whose rules changed after 2024.
4. Keep windows ≤ 400 days.
5. Any change in semantics changes `docs/spec/schedule.md`, these vectors and
   both implementations in the same pull request.
