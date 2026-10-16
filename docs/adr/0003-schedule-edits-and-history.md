# ADR 0003 — Schedule edits, ending a medication, and dose history (milestone 2.2)

- Status: accepted (owner decision on the PR #7 review)
- Date: 2026-10-16
- Scope: Flutter app screens (`app/lib/src/features`); TZ §2.1 (privacy), §2.2, §2.4;
  `docs/spec/schedule.md` (unchanged)
- Related: PR #7 (screens), ADR 0001 (local notifications)

## Context

Occurrences are not stored: the app (and the server's missed-dose detector)
expands them from a schedule's rule, and a dose event refers to an occurrence
only by its key `{schedule_id}/{YYYY-MM-DD}T{HH:MM}`. Replacing the rule of a
schedule that has already produced occurrences therefore rewrites the past:
an 08:00 dose taken last week is no longer an occurrence once the time is
changed to 09:00, so the day loses its "taken" mark and turns "missed" in the
history. The same happens when a medication or schedule is deleted although
the user only meant "I no longer take it". The history must not change when
the plan changes.

## Decisions

1. **Editing a schedule that has started splits it.** If the schedule's
   `start_date` is before today (the date in the medication's effective zone,
   docs/spec/schedule.md §3.1, like the rule's dates), saving an edit
   - ends the old schedule: its rule is kept as is, with `end_date` =
     yesterday (an earlier `end_date` is kept);
   - creates a new schedule of the same medication with the edited rule,
     starting today (or at the edited `start_date` if that is later).
     For `interval_days`, a start moved to today keeps the old phase: the new
     start is the first day on or after today that the edited rule's own
     `start_date` and interval would hit.

   Past occurrences keep their keys, so their marks stay valid. Today's
   occurrences come from the new schedule; marks recorded today on the old
   schedule's occurrences stay in the history of that schedule but are not
   carried over (the new occurrence starts unmarked; this is rare and
   visible, unlike a silently rewritten past).
2. **Schedules that start today or later are edited in place**
   (`start_date` >= today): no past day has occurrences, nothing in the
   history can change. (Marks recorded today on such a schedule behave as in
   a split: an occurrence whose time changed starts unmarked.) Ended
   schedules (`end_date` < today) are shown as ended and are not edited; a
   new schedule resumes the medication.
   An edit that leaves the rule unchanged writes nothing. An edit of a started
   schedule may not end the course before today: stopping is decision 3.
3. **Ending vs deleting.** Deleting a medication or a schedule that has
   history (it started before today) offers two choices:
   - **"Finish (history is kept)"** — `end_date` = yesterday on its running
     schedules; schedules that have not started are deleted. The medication
     stays and is listed as *archived* in a collapsed section of the
     medication list: no future occurrences means no reminders and no
     missed-dose pushes.
   - **"Delete with history"** — the real delete (tombstone). Its dose events
     stay on the server (append-only, TZ §2.4) but no longer count anywhere
     because nothing expands the occurrences they refer to.

   Without history (nothing started before today) only the delete is
   offered; for an ended schedule only "Delete with history" (finishing it
   again would change nothing). A medication is *archived* when it has
   schedules and all of them have ended.
4. **History counts ended schedules** like running ones: a schedule
   contributes the occurrences inside its `[start_date, end_date]`.
5. **History matches events by occurrence key.** Scheduled events are loaded
   by the keys of the expanded occurrences (per schedule, the key range of the
   displayed days, one day of margin for fixed-zone medications), not by the
   time the event was recorded, so a dose marked days late still counts.
   Only as-needed intakes (no occurrence) are windowed by `at`; their undos
   are read from the window start on, since an intake may be undone later.
6. **The effective mark of an occurrence is the last non-undone `taken` or
   `skipped` event by `at`** (ties: the larger event id, so every device
   picks the same event whatever order sync delivered them in).
   `snoozed` never marks. Marking an occurrence that already carries the same
   effective mark is a no-op (checked inside the write transaction), and the
   UI ignores repeated taps while a write for the same occurrence is running.
   An `undo` of an event that is already undone is likewise a no-op.
7. **Default privacy stays `shared`.** Nothing is visible to anybody until a
   relative is explicitly granted access (Phase 3). The grant screen will list
   which medications that relative will see (`shared` with name,
   `anonymous` as time and status only, `hidden` not at all), so the default
   is reviewed at the moment it starts to matter.

## Consequences

- An edit may leave several schedules per medication; the medication screen
  lists running and ended ones separately. Sync and the server need no change:
  both writes are ordinary schedule upserts in one local transaction.
- Reminders (2.3) follow automatically: ended schedules expand no future
  occurrences.
- Account deletion and export (Phase 5) cover ended schedules and archived
  medications like any other rows.
