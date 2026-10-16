# ADR 0002 — Protection of local data on the device (milestone 2.1)

- Status: proposed (owner review)
- Date: 2026-10-16
- Scope: Flutter app data layer (`app/lib/src/data`); TZ §2.6 (encryption), §3, `.claude/rules/privacy.md`
- Related: PR #6 (data layer and sync client)

## Context

The app keeps medication names, schedules and dose history in a local SQLite
database (drift) and the session in the platform keystore. Reviews of PR #6
found that local data was not bound to an account, that backups could copy
the database (and with it the per-install `device_id` used as the sync
tie-break) to another device, and that release builds could talk plain http.

## Decisions (implemented in 2.1)

1. **Local data belongs to one account.** `sync_state.user_id`/`region` hold
   the JWT `sub`/`region` the data was synced for; binding happens only when
   tokens are stored (verify-email, login, refresh). Signing in as another
   account, and an explicit logout (after a best-effort push of the outbox),
   erase profiles, medications, schedules, dose events, the outbox and the
   pull cursor in one transaction (`AppDatabase.wipeAccountData`). The cursor
   resets to 0 because server sequence numbers are global. A **forced**
   sign-out (refresh token expired or reused) only forgets the tokens: the
   data stays bound to its account, so signing in again as the same account
   pushes the pending outbox and nothing is lost, while another account
   erases it first. The sync engine never binds: it runs only when the data
   is bound to the token's account (else `account_changed`), re-checks the
   binding inside every transaction, and the API client refuses to send a
   request for one account's data with another account's token (checked
   before sending and before the retry after a refresh). Data written before
   the first sign-in is adopted by the account that signs in.
2. **Tokens** live in the keystore as one JSON value (atomic replace):
   iOS `first_unlock_this_device` (no iCloud Keychain sync, available to
   background sync after the first unlock), Android encrypted preferences
   with `resetOnError`. Unreadable entries read as signed out. The iOS
   Keychain survives an uninstall, so the first launch of a new install
   deletes everything the app stored there (flag in `sync_state`).
3. **No Android backups**: `allowBackup="false"`, and
   `fullBackupContent` / `dataExtractionRules` exclude every domain. The
   database is therefore never restored, and `device_id` (generated with the
   database) is per installation.
4. **https only** outside debug builds: `ApiConfig.fromEnvironment` throws
   for a non-https base URL unless `kDebugMode`.

## Open tasks

- **Schema version before the first release.** Local schema changes made
  during Phase 2 (e.g. the `sync_state` account columns) were folded into
  `schemaVersion` 1 because no installation exists yet. From the first
  public build on, every change bumps `schemaVersion` with a migration step.
- **Unsent changes on logout (2.2, UI).** Explicit logout erases changes the
  best-effort push could not send; the UI should warn when the outbox is not
  empty (`SyncEngine.watchPendingCount`).

- **iOS backup exclusion.** The database file under Application Support /
  Documents is included in iCloud and Finder backups by default. Task: set
  `NSURLIsExcludedFromBackupKey` on the database directory at start-up
  (a small platform channel or `path_provider` + a plugin), with a test on
  the Dart side that the call is made before the database opens. Until then
  an iOS backup restored to a new device carries the database and the old
  `device_id` (sync stays correct — keys are per write — but the tie-break
  device id is shared with the old device).
- **Encryption at rest (SQLCipher) — decision pending.** TZ §2.6 requires
  "шифрование на диске". Both platforms already encrypt app storage when
  the device is locked (iOS Data Protection, Android FBE). SQLCipher
  (`sqlcipher_flutter_libs` with drift) would add protection against
  extraction from an unlocked/rooted device at the cost of APK size (~3–4 MB),
  key management in the keystore and a migration of existing databases.
  To decide with the owner before the first public release.
