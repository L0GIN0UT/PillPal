# Reminder planner — specification

Status: normative. Source requirements: `docs/TZ.md` §2.2–2.3, §3 ("a reminder
fires without network and after a reboot"). Implementation:
`packages/pillpal_core/lib/src/reminders/` (pure Dart, no IO, no Flutter).
Platform mapping: `docs/adr/0001-local-notifications.md`.

The **reminder planner** turns schedules plus the user's dose marks into the
exact set of local notifications the device must have pending right now. It is
a pure, deterministic function: the same input yields the same output, byte for
byte, so the app can re-run it at any time (start, foreground, after a mark or
a sync, on boot, on a time-zone change) and reconcile the platform's pending
notifications against it.

The planner never re-implements schedule semantics: occurrences, keys,
instants and DST handling come from the schedule engine (`expand`,
`docs/spec/schedule.md`). The planner only decides **which notifications** to
derive from those occurrences, **when** they fire and **which id** they get.

The key words MUST, MUST NOT, SHOULD are used as in RFC 2119.

---

## 1. Input

| Input | Meaning |
|---|---|
| `now` | Current instant (any `DateTime`, compared as an instant). Injected; the planner never reads a clock. |
| `deviceTz` | IANA zone of the device, used for sources with `tzMode = local`. |
| `sources` | Reminder sources, see §1.1. |
| `handledKeys` | Occurrence keys that have a `taken` or `skipped` dose event (after `undo` is applied by the caller). |
| `snoozedUntil` | Map occurrence key → instant the occurrence is snoozed until (the latest `snoozed` event wins; the caller resolves that). |
| `budget` | Maximum number of notifications the planner may return (§5). |
| `horizon` | How far ahead the plan reaches (default 48 h, at most 30 days). |

### 1.1 Reminder source

One source per **schedule** (a medication with several schedules has several
sources).

| Field | Constraint |
|---|---|
| `medicationId`, `scheduleId` | non-empty strings (canonical lowercase UUIDs); `scheduleId` unique among all sources |
| `rule` | a validated `ScheduleRule` (v1) |
| `tzMode` | `local` → effective zone is `deviceTz`; `fixed` → effective zone is `fixedTz` |
| `fixedTz` | IANA zone, required iff `tzMode = fixed` |
| `level` | `quiet` \| `normal` \| `persistent` \| `alarm` (TZ §2.3) |
| `repeatEveryMinutes` | `N`, integer `1..720`; used only by repeating levels |
| `maxRepeats` | `M`, integer `0..50`; used only by repeating levels |
| `enabled` | `false` → the source produces nothing |

Violations are caller errors (`ArgumentError`). An unknown IANA zone is **not**
a caller error: the source is reported in `unplannableScheduleIds` (§6) and
every other source is still planned, so one bad zone never silences the other
medications.

**Repeating levels** are `persistent` and `alarm`. For `quiet` and `normal`
the planner behaves as if `M = 0` (one notification per occurrence).

## 2. Series of an occurrence

For each enabled source the planner expands its rule with the engine in the
effective zone over the window

```
[now − N·M minutes, now + horizon)        (repeating levels)
[now,              now + horizon)         (quiet, normal)
```

so that an occurrence in the recent past whose repeats are still due is found
(its **grace window** is exactly its repeat span `N·M`).

For an occurrence `o` with instant `t` the **regular series** is

| repeatIndex `k` | fire time |
|---|---|
| `0` (first notification) | `t` |
| `1..M` (repeats, repeating levels only) | `t + k·N` minutes |

Repeats are spaced in **elapsed time** (UTC instants), not wall-clock time: a
DST transition between two repeats does not stretch or shrink the interval.

A repeat (`k ≥ 1`) MUST be strictly before the instant of the **next
occurrence of the same schedule** (the next element after `o` in the engine's
sorted result). The newer dose supersedes the nagging for the older one; the
older one stays visible on the Today screen. When two keys share an instant
(DST gap, `docs/spec/schedule.md` §3.1), the earlier key therefore gets no
repeats; both first notifications are still planned.

## 3. Handled and snoozed occurrences

- An occurrence whose key is in `handledKeys` produces **nothing** — neither
  its regular series nor a snooze series.
- An occurrence whose key is in `snoozedUntil` (and is not handled) produces
  **no regular series**. Instead it produces the **snooze series**: the
  snooze replaces the original notifications, it never duplicates them.

### 3.1 Snooze series

With `s = snoozedUntil[key]`:

| repeatIndex `k` | fire time | `isSnooze` |
|---|---|---|
| `0` | `s` | true |
| `1..M` (repeating levels only) | `s + k·N` minutes | true |

The snooze series restarts the repeat counter and is **not** cut by the next
occurrence (a snooze is an explicit user request).

A snooze entry is applied only if its key denotes a real occurrence of an
enabled source: the key's schedule id names an enabled source, the key has
the canonical form `"{scheduleId}/{YYYY-MM-DD}T{HH:MM}"`, the rule qualifies
that local date (`ScheduleRule.occursOn`) and has a slot at that time.
Otherwise the entry is stale (the schedule was edited or deleted) and is
ignored. A snooze does not depend on the occurrence's instant or on the
source's zone, so it works for any past occurrence still shown on the Today
screen, even when the source is unplannable (§6).

## 4. Fire-time filter

From all series the planner keeps the **candidates** whose fire time `f`
satisfies

```
now < f < now + horizon
```

A fire time `≤ now` is considered delivered by an earlier plan (or missed
while no plan existed); the planner never re-delivers it. The Today screen,
not a notification, shows due and overdue doses. The bound is strict on both
sides so that a platform API that rejects past dates never sees `now`.

## 5. Budget

Platforms limit pending notifications: iOS keeps at most **64** per app
(`iosPendingNotificationLimit`); Android's AlarmManager caps alarms per app
(500 on stock Android, lower on some OEM builds), so the default Android
budget is **400** (`androidDefaultNotificationBudget`). The app passes the
budget, minus any slots it reserves for other notifications.

**Policy: earliest-first prefix.** Candidates are totally ordered by

1. fire time, ascending;
2. first notifications (`repeatIndex = 0`, including a snooze's first) before
   repeats;
3. occurrence key, ordinal string comparison;
4. `repeatIndex`, ascending;

and the planner keeps the first `budget` candidates in this order. Hence:

- every kept notification fires no later than every dropped one, so the plan
  is **complete for every instant before `replanBefore`** (§6);
- a first notification is never dropped in favour of a later repeat, and at
  the same instant first notifications win over repeats;
- dropping is always a suffix in time, so re-running the planner later only
  appends (the window slides) and keeps ids of already pending items stable.

The output list is in this order.

## 6. Output

```
ReminderPlan {
  requests: [NotificationRequest]   # ordered as in §5
  replanBefore: instant
  droppedByBudget: int
  unplannableScheduleIds: {string}
}
NotificationRequest {
  id: int                 # §7
  occurrenceKey, medicationId, scheduleId: string
  fireAtUtc: instant (UTC)
  repeatIndex: int        # 0 = first notification of the series
  level: quiet|normal|persistent|alarm
  isSnooze: bool
}
```

- `replanBefore` = the fire time of the first candidate dropped by the budget,
  or `now + horizon` if nothing was dropped. The app MUST re-run the planner
  before that instant (best effort on iOS: on launch, foreground, background
  refresh, notification action); after it, reminders may be missing.
- `droppedByBudget` = number of candidates not returned because of the budget.
- `unplannableScheduleIds` = enabled sources whose effective zone is unknown
  (§1.1), sorted. The app SHOULD tell the user.

Notification payloads and logs MUST NOT carry medical data
(`.claude/rules/privacy.md`): a request holds only opaque ids, the key, the
fire time and the level; the app chooses the visible text according to the
medication's privacy setting.

## 7. Notification ids

Platforms identify notifications by a 32-bit signed integer, so ids are in
`1..2^31−1`.

1. **Base id**: `FNV-1a-32(utf8(input)) & 0x7fffffff`, where `input` is
   `"{occurrenceKey}#{repeatIndex}"` for a regular series and
   `"{occurrenceKey}#s{repeatIndex}"` for a snooze series. A base id of `0`
   becomes `1`. FNV-1a-32: offset basis `0x811c9dc5`, prime `0x01000193`,
   for each byte `h = (h XOR byte) · prime mod 2^32`.
2. **Collisions** are resolved by linear probing, visiting the kept requests
   in output order (§5): a request takes its base id if still free, else the
   next free id `base+1, base+2, …`, wrapping from `2^31−1` to `1`. Earlier
   requests — the ones already pending from a previous plan — keep their base
   id when a later one collides with them.

Ids depend only on the key, the repeat index and whether the series is a
snooze, so they survive a time-zone change and re-planning; a request whose
fire time changed keeps its id and the platform replaces it in place
(scheduling an existing id replaces the pending notification).

## 8. Reconciliation

`reconcile(previous, next)` computes the minimal platform update from the
previously scheduled requests to a new plan:

- `cancelIds` — ids of `previous` that are absent from `next`, ascending;
- `schedule` — requests of `next` that are new or differ in any field from the
  request with the same id in `previous`, in plan order.

Scheduling an existing id replaces it, so a changed request is not cancelled
first. The app keeps `previous` in its local database (or rebuilds it from the
platform's pending requests and their payloads). Applying the same plan twice
is a no-op.

## 9. Time zones

- `tzMode = local`: the engine runs in `deviceTz`. When the device zone
  changes, keys stay the same, instants move with the wall clock, ids stay the
  same and reconciliation re-schedules the moved requests.
- `tzMode = fixed`: the engine runs in `fixedTz`; a device zone change does not
  move anything.

## 10. Examples

All with `now = 2026-10-16T05:00Z`, `deviceTz = Europe/Samara` (UTC+4),
horizon 48 h, schedule `S` daily at 08:00 and 20:00 (= 04:00Z and 16:00Z).

| Situation | Requests from `S` in the first day |
|---|---|
| `normal` | `S/2026-10-16T20:00#0` at 16:00Z (08:00 already passed) |
| `persistent`, `N = 30`, `M = 3` | `S/2026-10-16T08:00#3` at 05:30Z (repeats `#1`, `#2` at 04:30Z, 05:00Z are not after `now`), then `S/2026-10-16T20:00#0..3` at 16:00Z, 16:30Z, 17:00Z, 17:30Z |
| same, 08:00 taken | 08:00 produces nothing |
| same, 08:00 snoozed until 05:15Z | `S/2026-10-16T08:00#s0` at 05:15Z, `#s1..s3` at 05:45Z, 06:15Z, 06:45Z |
| same, budget 2 | 05:30Z and 16:00Z kept; `replanBefore = 16:30Z` |
