# ADR 0019 — Device-side report history and file actions

- Status: Accepted (owner decisions 2026-11-11, prototype approved 2026-11-11)
- Date: 2026-11-11
- Scope: TZ §2.4 ("PDF-отчёт для врача"); app `features/report/` (`report_history.dart`,
  `report_actions.dart`, `report_scope.dart`, `report_service.dart`), `data/db/report_tables.dart`
  (schema 9), `reminders/{providers,reminder_session}.dart`, Android `ReportChannel.kt`,
  `ReportFileProvider.kt`, `res/xml/report_paths.xml`, manifest; privacy policies RU/EN/EU
- Related: ADR 0002 (local data protection), ADR 0005/0006 (relatives and privacy projection),
  ADR 0010 (account deletion), `.claude/rules/privacy.md` rules 1, 5, 7, `docs/phase5-plan.md`

## Context

A report was made on the device, copied to a temporary folder and handed to the share sheet; the
copy was deleted at the next start. The owner wants to open the report, save it where he chooses
(Downloads, Drive) and find earlier reports again ("Мои отчёты"). A PDF is the most concentrated
medical artefact the app makes, so every place it rests and every way it leaves must be decided and
bounded. No server is involved: reports never leave the device except by the person's own action.

## Decision

### 1. Where reports rest
The PDF is kept in the app's **private** storage: `getApplicationSupportDirectory()/reports/<id>/
pillpal-report-<first>-<last>.pdf` (Android `filesDir`). Dates only in the name; no profile name,
no medication. Metadata is the drift table `stored_reports (id, profile_id, first_day, last_day,
include_hidden, created_at, size_bytes)`, schema 8 -> 9, a new empty table, no data rewrite.
It holds no names or medical values either. By design it has no foreign key or CHECK: profiles
and reports are not synced together (a pulled child may precede its parent, as in the other
local tables), so the cascades live in code (`wipeAccountData`, `evictScope`) and in `reconcile`. Android backup and device transfer already exclude
`files/` and databases (ADR 0002, `backup_rules.xml`, `data_extraction_rules.xml`).
**iOS**: files in Application Support are included in iCloud and Finder backups, exactly like the
local database (privacy policy: planned fix). The backup exclusion of the app's storage is one
change for both; until it ships, the policy already tells iOS users the database may be in the
backup.

### 2. Limits
At most **20** reports and **90 days** (constants in `report_model.dart`). When the limit is hit
the oldest report is deleted silently when a new one is created; expired ones are deleted then and
by `reconcile`. Retention is a device-side bound, not a server one.

### 3. Lifecycle (`ReportHistory`)
`add`, `fileOf`, `delete`, `deleteAll`, `reconcile`, one operation at a time (a serial queue), so
`reconcile` never deletes the file of a report being added. `reconcile` deletes rows older than 90
days, rows whose profile is gone or whose file is missing, and every file or folder that has no row.
It runs at app start and at the end of every sync run, failed ones too, because a pull that
evicted a scope commits before the run fails (`ReportScope`). A tombstoned profile counts as gone.

### 4. Cascades
- `AppDatabase.wipeAccountData` deletes all rows; `evictScope(profileId)` deletes that profile's
  rows. Their files go at the next `reconcile` (orphans) or at `deleteAll`.
- On **this device** `deleteAll` (the whole `reports/` folder, tried twice, then the rows; the rows stay
  if the folder cannot be deleted) runs on sign-out, except the sign-out that keeps the local data
  (`keepLocalData`, as a forced one), and when another account signs in
  (`ReminderSessionListener`); a deletion request wipes the requesting device the same way. The
  account wipe has already removed the rows by then, so a failed folder delete leaves only
  orphan files, which the next `reconcile` removes (residual window: until the next start or sync
  run). A **forced** sign-out wipes nothing, as for the rest of the local data (ADR 0002).
- On **other devices of the same account** a report stays until that device signs out, signs in
  with another account, or the 90 days pass, whichever comes first: devices do not talk to each
  other and the server knows nothing about reports.
- **Relatives.** A stored PDF of a relative's profile keeps what was visible when it was made
  (`shared`/`anonymous` projection, no `hidden`). It is **deleted when access ends**: eviction of the
  scope removes the row and `reconcile` the file. Accepted: between the revoke and the next sync the
  device may still hold it, as it holds the relative's data until then (ADR 0006 §8).
- Copies the share plugin makes (`<cache>/share`, iOS `tmp/`) stay cleaned at start and on
  sign-out (`ReportFiles`).

### 5. File actions (`ReportActions`)
Android: platform channel `pillpal/reports` (`ReportChannel.kt`), no new Flutter dependency, no new
permission.
- `saveAs`: `ACTION_CREATE_DOCUMENT` (storage access framework: the person picks the place and the
  app gets write access to that one document only), then copy off the main thread.
- `open`: `ACTION_VIEW`; `share`: `ACTION_SEND` + `EXTRA_STREAM` + `ClipData` through a chooser.
- Both use `content://` Uris of `ReportFileProvider` (authority `${applicationId}.reports`,
  `exported=false`, `grantUriPermissions=true`) with a one-file read grant. `report_paths.xml` maps
  `files/reports/` only. The provider is a subclass, so it cannot merge with a library's declaration.
- Only an **absolute path** crosses the channel. The native side canonicalises it (symlinks, `..`)
  and accepts a `.pdf` file strictly inside `filesDir/reports`; else the error `invalid_path`. The
  file name for the save dialog comes from the validated file, never from Dart.
- One call at a time: while a save waits for the picker or copies, any call answers `busy`.
- Failures answer the fixed code `io_error` (no message); a lost save answer is bounded by a
  10-minute timeout on the Dart side, and an answer for a save nobody waits for deletes the
  document the picker created. The save copy is opened with mode `wt` and a failed copy deletes
  the half-written document.
- No viewer app: `no_app`; the UI offers "Save" instead (milestone 3 of the plan).
iOS: all three go to `Printing.sharePdf` (the share sheet offers Files, Print and apps).

Once the person is offered to open, save or share a report (the system shows the viewer,
picker or chooser), the file is outside the app's control (another
app, Drive, a messenger). The report sheet says so in its «Отчёт готов» state and tells the result of every
`ReportActionResult` (`docs/design.md`, History); «Мои отчёты» (`/reports`) lists the kept reports.

### 6. Logging
Nothing about reports is logged: not names, dates or sizes. Failures are swallowed or shown as the
generic error; `PlatformException` codes are fixed words (`busy`, `invalid_path`, `io_error`).

## Consequences
- The device holds up to 20 PDFs of medical data for up to 90 days, in private storage, deleted
  with the account data. The policy lists this (section 4.1 and the retention table).
- New table is device-only: no sync entity, no server change, no export change (the export covers
  server data; the reports are derived from it).
- Release builds need `androidx.core` explicitly (FileProvider); it was already transitive.

## Alternatives considered
- **Store parameters only, regenerate on demand.** Smaller footprint, but an old report would change
  with later edits, which defeats a record for the doctor; rejected by the owner (answer 1).
- **`MediaStore` / Downloads without a picker.** Needs storage permission on old Android and leaves
  the file in a shared location by default; SAF keeps the choice with the person.
- **A pub package for the intents (`open_filex`, `share_plus`).** New dependency and its own
  provider declaration for something thirty lines of Kotlin do.
