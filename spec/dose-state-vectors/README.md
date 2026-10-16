# Dose-state test vectors

Shared, language-neutral test cases for the dose-state contract specified in
[`docs/spec/dose-state.md`](../../docs/spec/dose-state.md): the effective mark of
an occurrence, its latest snooze, its due instant, and when it is missed. The
**same files** are executed by both implementations:

| Implementation | Test that runs every vector |
|---|---|
| Python (`backend/app/domain/dose_state.py`) | `backend/tests/domain/test_dose_state_vectors.py` |
| Dart (`packages/pillpal_core`) | `packages/pillpal_core/test/doses/dose_state_vectors_test.dart` |

CI additionally runs `python spec/validate_vectors.py` (stdlib only) from the
repository root, which checks the structure and internal consistency of the
files (shape per [`schema.json`](schema.json), unique names, ASCII ids,
`expected.due = max(occurrence_at, expected.snooze_until)`, `missed` verdicts
against `expected.due`, at least 30 cases).

## Files

| File | Covers |
|---|---|
| `marks.json` | no events, taken, skipped, undo, taken-undo-taken, later `at` wins, equal `at` (larger id wins, either input order), undo order independence and clock skew, undo of an undo, undo of an unknown or foreign event, events of other occurrence keys, an event without an occurrence key, an undo without a target, microsecond ordering (`at` before id) |
| `snooze.json` | latest snooze by `at` (not by `snooze_until`), equal `at`, undone snoozes, `snooze_until` before / equal to the occurrence instant or to `at`, a snooze without `snooze_until`, later `at` with the smaller id, snooze next to a mark, other keys |
| `missed.json` | exact `due + X` boundary (1 microsecond before / at), `X = 0`, snoozed due, marked before and after `due + X`, undone mark / snooze, undone mark with a live snooze, other keys |

## Case format

```json
{
  "name": "snoozed_then_missed_at_snooze_until_plus_x",
  "description": "optional, explains the hand derivation",
  "occurrence_key": "sched-t01/2026-10-17T08:00",
  "occurrence_at": "2026-10-17T04:00:00Z",
  "events": [
    { "id": "evt-s1", "type": "snoozed", "at": "2026-10-17T04:05:00Z",
      "occurrence_key": "sched-t01/2026-10-17T08:00",
      "snooze_until": "2026-10-17T04:20:00Z" }
  ],
  "expected": { "mark": null, "snooze_until": "2026-10-17T04:20:00Z", "due": "2026-10-17T04:20:00Z" },
  "missed": [
    { "now": "2026-10-17T04:49:59.999999Z", "grace_minutes": 30, "expected": false },
    { "now": "2026-10-17T04:50:00Z", "grace_minutes": 30, "expected": true }
  ]
}
```

Instants are UTC, `YYYY-MM-DDTHH:MM:SS[.f{1,6}]Z` (microsecond precision
matters for the `missed` boundary). An event has `id`, `type`
(`taken|skipped|snoozed|undo`), `at`, `occurrence_key` (string or `null`) and,
as in the API, `target_event_id` (for `undo`) and `snooze_until` (for `snoozed`).
Both are optional here: the write-path rules (an undo has a target, a snooze has
`snooze_until`) are not required, so that vectors can pin the unusual inputs.
Ids match `^[a-z0-9-]+$` and are compared ordinally. `expected.mark` is `null` or `{event_id, type, at}`;
`expected.snooze_until` is `null` or an instant. Ids are synthetic.

A runner MUST: take the events of the case, compute the state of
`occurrence_key` **from the whole event list** (events of other keys are part
of the input and must be ignored, undos apply by target), and assert that
`mark`, `snooze_until` and `due(occurrence_at)` equal `expected`; and for every
`missed` probe assert `is_missed(occurrence_at, now, grace_minutes) ==
expected`. A runner SHOULD also shuffle or reverse the event list and assert
the same result (the contract is order independent).

## Rules for adding vectors

1. Derive `expected` **by hand** from the spec (write the reasoning into
   `description`); never paste implementation output as the expected value.
2. Names are unique within this directory (`^[a-z0-9_]+$`).
3. Ids are synthetic (`evt-a`, `evt-s1`); no real data.
4. Any change in semantics changes `docs/spec/dose-state.md`, these vectors and
   both implementations in the same pull request.
