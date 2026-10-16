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
| `retained` | Requests already applied to the platform and not yet settled (§8.2) — pending, delayed or delivered. Their ids are reserved (§7). |

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

A fire time `≤ now` is never planned again: an earlier plan already handed
it to the platform, which may still deliver it late (inexact alarms, Doze) —
the app keeps it as retained until it is settled (§8.2). If no plan existed
at that time, the Today screen, not a notification, shows the due dose. The bound is strict on both
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
- dropping is always a suffix in time, so re-running the planner later
  mostly appends (the window slides); ids stay stable through `retained`
  (§7).

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

Platforms identify notifications by a signed 32-bit integer. The id space is
split: **planner ids are `1..0x3fffffff`** (`plannerIdMask`); ids from
`0x40000000` (`firstAppNotificationId`) up to `0x7fffffff` belong to the app
for notifications the planner does not make (low stock, sync prompts), so
the two can never collide.

1. **Identity and base id**: the identity of a request is
   `"{occurrenceKey}#{repeatIndex}"` for a regular series and
   `"{occurrenceKey}#s{repeatIndex}"` for a snooze series. Its base id is
   `FNV-1a-32(utf8(identity)) & 0x3fffffff`; a base id of `0` becomes `1`.
   FNV-1a-32: offset basis `0x811c9dc5`, prime `0x01000193`, for each byte
   `h = (h XOR byte) · prime mod 2^32`.
2. **Reserved ids**: every id of `retained` is reserved. Visiting the kept
   requests in output order (§5), a request whose identity equals that of a
   retained request takes that request's id back (**sticky**). Any other
   request takes its base id if it is neither reserved nor taken, else the
   next free id `base+1, base+2, …`, wrapping from `0x3fffffff` to `1`
   (linear probing).

Sticky allocation keeps an id with its occurrence across plans even when the
request it collided with has fired and left the plan, and a new request never
takes the id of a notification that may still be pending or in the tray
(scheduling that id would replace it). Without `retained`, ids depend only on
the identity and the order of the kept requests. A request whose fire time
changed (time-zone change, re-snooze) keeps its id; the platform replaces it
in place.

## 8. Applying a plan

The app stores what it applied as `AppliedNotification`s: a request plus two
opaque fingerprints it computes itself.

| Fingerprint | Covers | Example input |
|---|---|---|
| `displayFingerprint` | how the notification looks and is delivered | Android channel / iOS interruption level, exact vs inexact mode, medication privacy (`shared` / `anonymous` / `hidden`), locale, text variant |
| `scheduleFingerprint` | the schedule state the request was planned from; a change invalidates notifications already shown | schedule `version`, medication `version` (rule, `tz_mode`, privacy) |

It keeps an applied notification — including one whose fire time has passed
— until it is **settled** (§8.2) or older than the app's retention window
(the Today screen's range; at least the longest repeat span). A fire time
`≤ now` does **not** mean delivered: Android may delay inexact alarms and Doze
defers even exact ones.

### 8.1 Reconcile

`reconcile(previous, next, now)`: `previous` are the retained applied
notifications, `next` the new plan's requests wrapped with their current
fingerprints. Only `previous` entries with a fire time `> now` take part;
past ones are left to settling.

- `cancelIds` — ids of those entries that are absent from `next`, **or whose
  `displayFingerprint` differs** from the `next` entry with the same id
  (they are cancelled and rescheduled under the same id, so a medication made
  `hidden` loses its name on the lock screen and a newly granted exact-alarm
  permission upgrades pending reminders); ascending.
- `schedule` — `next` entries that are new or differ in any way from the
  `previous` entry with the same id, in plan order.

The app cancels first, then schedules (iOS keeps only the 64 most recently
set requests). Applying the same plan twice is a no-op.

### 8.2 Settle

`settleIds(retained, handledKeys, snoozedKeys, liveSchedules)` returns the ids
(ascending, unique) to cancel **whatever their fire time** — pending, delayed
or delivered; cancelling also removes a delivered notification from the tray.
A retained notification is settled when

- its occurrence key is in `handledKeys` (taken or skipped);
- it belongs to a regular series (`isSnooze = false`) and its key is in
  `snoozedKeys` — the snooze series replaces it;
- `liveSchedules` (schedule id → current `scheduleFingerprint` of every
  **enabled** source) has no entry for its schedule (deleted or disabled) or a
  different fingerprint (edited; the plan re-creates what is still due).

Order per re-plan: settle (cancel, forget), plan with the remaining retained
requests, reconcile, cancel, schedule, store.

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
