# ADR 0005 — Relatives: roles, permissions and managed guardianship (Phase 3)

- Status: accepted
- Date: 2026-10-16 (revised after the PR #12 reviews)
- Scope: TZ §2.1 (per-medication privacy), §2.5 ("Близкие"), §5 "Фаза 3"; backend
  `profile_grants`, `invites`, `app/services/access.py`; app Family tab
- Related: `docs/phase3-plan.md` (owner decisions D1, D3), ADR 0006 (sync scopes and
  privacy projection), ADR 0009 (invite links), ADR 0010 (account deletion), ADR 0003 §7
  (privacy default)

## Context

TZ §2.5 asks for a symmetric model: every person has their own account, and a profile
owner grants another account `view` or `view+edit` on their profile, by link or QR, with
the invitee confirming. Managed profiles (grandma without a smartphone, a child, a pet)
are run by guardian accounts, and their reminders fire on guardians' phones. Per-medication
privacy (`shared` / `anonymous` / `hidden`, TZ §2.1) must hold on every path that faces a
relative (`.claude/rules/privacy.md` rule 5).

Phase 1 already has `profiles.kind ∈ {self, managed}` and `profiles.owner_user_id`; every
query is scoped by the owner. Phase 3 adds a second axis: who else may see or change a
profile, and how much of it.

## Decision

### 1. Roles

| Role | Where it comes from | Profiles | Access class |
|---|---|---|---|
| `owner` | `profiles.owner_user_id` | self and managed | full |
| `guardian` | `profile_grants.role = 'guardian'` | managed only | full |
| `editor` | `profile_grants.role = 'editor'` ("view+edit") | self and managed | projected |
| `viewer` | `profile_grants.role = 'viewer'` ("view") | self and managed | projected |

- The owner of a managed profile is its primary guardian; co-guardians are grants.
- Full-access roles see everything, including `hidden` medications: privacy protects the
  profile from relatives, not from the people who run it.
- Projected roles see the privacy projection (ADR 0006 §3).
- DB invariants (triggers, not only code): one grant per `(profile, grantee)`; the grantee
  is never the owner (checked on grant insert and role change, and on a change of
  `profiles.owner_user_id`); `guardian` only on managed profiles; no new grant on a
  tombstoned or archived profile. `notify_missed` updates are not guarded.

### 2. Access matrix

| Capability | owner (self) | owner (managed) | guardian | editor | viewer |
|---|---|---|---|---|---|
| Read profile (name, zone) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Read alert settings | ✓ | ✓ | ✓ | — | — |
| `shared` medications | full | full | full | full | full |
| `anonymous` medications | full | full | full | redacted | redacted |
| `hidden` medications | full | full | full | — | — |
| Create and update medications and schedules | all | all | all | `shared` only; `privacy` immutable; new ones `shared` | — |
| Delete medications and schedules | all | all | all | — | — |
| Record dose events (taken, skipped, snoozed, undo) | all | all | all | — | — |
| Edit profile, alert settings, privacy | ✓ | ✓ | ✓ | — | — |
| Invites and grants management | ✓ | ✓ | — | — | — |
| Delete profile | — (self is protected) | ✓ | — | — | — |
| Local reminders on own devices | ✓ | ✓ | ✓ (per-device toggle) | — | — |
| Missed-dose push | — (local reminders) | ✓ when the profile has co-guardians | ✓ | ✓ (opt-out) | ✓ (opt-out) |
| Owner's last sync hour (self scopes, D5) | — | — | ✓ | ✓ | ✓ |
| Leave (delete own grant) | — | — | ✓ | ✓ | ✓ |

**D3 — editors neither mark doses nor delete.** "View+edit" means helping maintain the
medication list and schedules (a daughter entering her father's new prescription), not
confirming intakes on someone's behalf: a mark states that the person took the medicine,
which only the person (owner) or the people who give it (guardians) can state. Deletes are
excluded too, because deleting a medication or schedule cascades into its history. Both are
rejected with `forbidden` on visible entities; the rule order and codes are in ADR 0006 §6.
The app shows editors no mark or delete buttons.

Relatives (`editor`, `viewer`) read and write only through sync; REST resource endpoints
stay limited to full-access roles (404 for others), so the projected surface is one code
path.

### 3. Grant lifecycle

- A grant is created only by accepting an invite (ADR 0009); its id is server-generated.
  It copies the invite's `disclosure_version`, the version of the disclosure screen the
  owner confirmed (what the relative will see); `created_at` is its timestamp. This is the
  Phase 3 record of the owner's decision to disclose; formal consent documents are Phase 5.
- The owner may change `role` between `viewer` and `editor` (and demote a `guardian`), sending
  the `disclosure_version` of the screen they confirmed, which is stored on the grant. **`guardian`
  is never granted by PATCH** (409 `guardian_requires_invite`): full access, including hidden
  medications and dose marking, needs a guardian invite with its 24 h TTL and the invitee's
  warning screen. The grantee may change `notify_missed`. A PATCH mixing the
  two, or a field the caller may not set, is a 422 (never partially applied). Anyone else
  gets 404.
- Revocation (owner) and leaving (grantee) are a hard DELETE; no link history is kept.
- Alert recipients are grants created before the occurrence was due: a new link does not
  flood the grantee with old alerts.
- The owner learns about a new link by a `link_accepted` push **and**, independent of push,
  a "new relative" banner in the Family tab.
- **Active grants.** A grant is active only while neither its grantee nor the profile's
  owner is `pending_deletion` (ADR 0010). Inactive grants are kept so a restore brings them
  back, give no access and no alerts, and are listed to the owner as `active: false` (no
  reason given) so the owner can revoke them during the grace period. On restore the owners
  of profiles the restored account holds grants on get a `link_restored` push (ids only)
  and the banner.
- At most `MAX_ACCESS_SCOPES_PER_USER` (100) accessible profiles per user, enforced when
  accepting an invite and creating a managed profile (`too_many_scopes`).

### 4. Invites (summary; details in ADR 0009)

Created by the owner for one profile and one role (`guardian` only on managed profiles);
single use; TTL 24 h for `guardian`, 7 days otherwise; at most 5 active per profile; the
token is shown once and stored only as `sha256`. The invitee previews and confirms
explicitly; nothing is accepted automatically.

### 5. Managed guardianship and the archive (D1)

A managed profile is owned by its primary guardian and may have co-guardians. Every
guardian gets local reminders on devices where "remind on this device" is on, marks doses,
edits medications and schedules, and receives missed-dose alerts. Only the owner manages
invites and grants and may delete the (non-archived) profile.

**When the owner's account goes away** (deletion request, ADR 0010), the managed profile
becomes a **read-only archive**: `archived_at` and `archive_reason` are set
(server-controlled; managed only; both or neither). For everyone, including a later owner:

- reminders stop (the scope carries `archived: true`, ADR 0006) and the detector skips it;
- every write is rejected with `read_only` (REST `409`, sync `rejected/read_only` with the
  current state); invites, new grants and role changes are refused;
- Today, History and the PDF report stay readable for owner and guardians;
- viewer and editor grants are inactive.

| | `owner_pending_deletion` | `owner_erased` |
|---|---|---|
| Set when | the owner requests deletion (only profiles not already archived) | the former owner is hard-erased |
| Readers | guardians (the owner cannot act) | the new owner and guardians |
| Guardians may | **only leave** | leave; owner or any guardian may **delete the archive** |
| Viewer/editor grants | inactive | deleted |
| Ends | restore (un-archived) or erasure | purge at `archive_purge_after` |

Guardians cannot delete the archive while the owner can still restore, so a restore always
finds the profile as it was ("no data has to be re-entered"). Restore un-archives only
profiles that are not deleted.

**At the hard erase** each archived profile moves to the **earliest active co-guardian**
(`ORDER BY grant.created_at, grant.id`, excluding guardians in `pending_deletion`); that
guardian's grant is deleted, `archive_reason` becomes `owner_erased`,
`archive_purge_after = now + MANAGED_ARCHIVE_RETENTION_DAYS` (default 365, configurable,
shown on the archive banner), and `updated_by_device` is cleared on the profile's rows.
Without an active co-guardian the profile is erased with the owner's data.

**Deleting an archive is a purge**, not a tombstone: the profile, medications, schedules,
dose events (through the append-only trigger's `pillpal.purge` path), journal rows, alerts
and grants are removed; devices see the scope disappear and evict it. The retention cron
does the same at `archive_purge_after`.

Keeping the archive is justified because its data is about the managed person, not the
deleted user, and the co-guardians already had full access to it; its legal basis is
listed for legal review (`docs/phase3-plan.md`).

### 6. Soft limits behind a flag

`FEATURE_SOFT_LIMITS` (default off), `SOFT_LIMIT_RELATIVES` (3, active grants on the owner's
profiles), `SOFT_LIMIT_PDF_REPORTS`. With the flag on, accepting beyond the limit fails with
`409 relatives_limit_reached`; `GET /v1/me/features` tells the app what to gate.

## Consequences

- New tables `profile_grants` and `invites`; `profiles` gains `archived_at`,
  `archive_reason`, `archive_purge_after`. All are in the erasure path and the inventory.
- `app/services/access.py` answers "which role does this user have here" and "which
  profiles may this user see", with three terms beyond ownership: grant exists, grant is
  active, and archived profiles admit only owner and guardian roles.
- Editors cannot mark or delete; a role that can (for example a nurse) would be new.
- An archive cannot be reactivated after `owner_erased` (follow-up if owners ask).

## Alternatives considered

- **ACL per medication:** privacy levels already express what relatives see per
  medication; per-medication grants would multiply invite flows and UI.
- **Editors mark `shared` doses** (planner default before D3): rejected by the owner.
- **Transfer the managed profile at once on the deletion request:** not reversible on
  restore, and a profile would change owners without that person's action.
- **Let guardians delete the archive during the grace period:** a restore would find the
  profile gone.
- **Keep archives forever after `owner_erased`:** violates minimization; 365 days default.
- **A separate `guardianships` table:** co-guardians are grants with a role; one table and
  one access predicate suffice.
