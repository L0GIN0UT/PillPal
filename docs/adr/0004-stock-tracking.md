# ADR 0004 — Stock tracking from a counted baseline (milestone 2.4)

- Status: accepted
- Date: 2026-10-16
- Scope: TZ §2.4 ("учёт остатка"); `medications.stock_count`, `stock_unit`,
  `low_stock_days`, new `stock_set_at`; app `lib/src/features/stock/`
- Related: ADR 0003 §6 (effective mark of an occurrence)

## Context

TZ §2.4 asks for "списание при отметке" and "осталось на N дней". The obvious
implementation decrements `stock_count` on every `taken` mark. Medications are
synced as whole rows with last-write-wins by `client_updated_at`: two devices
(or a notification action in the background and the app) that each decrement
the count offline produce two versions of the row, and LWW keeps one of them,
silently losing the other decrement. Undo would need an increment with the
same problem.

## Decision

1. **The stock is never decremented.** `stock_count` is the amount the user
   counted, and `stock_set_at` (new, nullable, `timestamptz`) is when. Both are
   written together, in the same LWW row, only when the user enters a count:
   the first count on the medication form or "Пополнить запас".
2. **The remaining amount is derived** on the client:
   `remaining = stock_count − Σ dose amounts taken after stock_set_at`, where
   - a scheduled occurrence counts when its effective mark (ADR 0003 §6) is
     `taken` and was recorded after the baseline; its amount is the dose of its
     time slot (from the occurrence key's schedule and `HH:MM`);
   - an as-needed intake (`taken` without occurrence, not undone) counts with
     the medication's single slot dose when all its slots agree, or one piece
     of a counted unit (tablet, capsule, drop, puff, sachet, unit, injection)
     when it has no slots; otherwise it cannot be computed.
   Dose events are append-only and merge without conflicts, so every device
   derives the same remaining amount once synced. Undo and skip need no
   special handling.
3. **Units.** The stock unit is one of the dose units (`docs/spec/schedule.md`
   §1.4). Doses are subtracted only in the same unit; a taken dose or a
   running schedule in another unit, or a free-text unit, shows "не удаётся
   посчитать" instead of a wrong number. No conversions (tablets ↔ mg).
4. **Days left** = remaining / consumption of the schedules running today
   (not yet started and ended ones excluded; as-needed counts 0), in integer
   arithmetic: each schedule consumes a whole number of thousandths per
   period (1 day `daily`, 7 days `weekdays`, N days `interval_days`); the
   periods are put over their least common multiple and
   `days = remaining × period ÷ consumption`, rounded down. (1 tablet Mon–Fri
   with 5 left lasts 7 days.) The low-stock banner shows when days left ≤
   `low_stock_days` (default 7).
5. Rows without `stock_set_at` (written before revision 0003) use the row's
   conflict key as the baseline; the next count stores a real one. Like the
   other stock fields, `stock_set_at` is erased from tombstones.

## Consequences

- One nullable column and an optional field in `MedicationData` /
  `MedicationOut`; sync semantics are unchanged.
- Amounts are summed as integer thousandths (they have at most 3 decimals),
  never as binary floating point.
- The remaining amount is not stored, so the server cannot warn about low
  stock by itself; a future server-side warning would apply the same rule.
- Editing other medication fields keeps the baseline: the form only shows the
  derived amount and offers "Пополнить запас" once a count exists, and its
  save asks the repository to keep the stored count and baseline (read in
  the write transaction), so a refill made meanwhile is never reverted.
  Choosing another unit for a counted stock requires a new count.
- A dose taken after the baseline from a schedule that no longer exists
  (deleted "with history", ADR 0003 §3, or not synced yet) has no known
  amount: the stock shows "не удаётся посчитать" until the next count
  ("Пополнить запас") instead of silently not subtracting it.
- Undos apply whenever they were recorded; only the marks themselves are
  compared with the baseline. As-needed intakes take their dose from the
  schedules running today.
