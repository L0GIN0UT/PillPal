# ADR 0005 — Relatives: roles, permissions and managed guardianship (Phase 3)

- Status: accepted
- Date: 2026-10-16
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
query is scoped by the owner. Phase 3 needs a second axis: who else may see or change a
profile, and how much of it.

## Decision

### 1. Roles

| Role | Where it comes from | Profiles | Access class |
|---|---|---|---|
| `owner` | `profiles.owner_user_id` | self and managed | full |
| `guardian` | `profile_grants.role = 'guardian'` | managed only | full |
| `editor` | `profile_grants.role = 'editor'` ("view+edit") | self and managed | projected |
| `viewer` | `profile_grants.role = 'viewer'` ("view") | self and managed | projected |

- The owner of a managed profile is its primary guardian. Co-guardians are grants.
- Full-access roles see everything, including `hidden` medications: privacy protects the
  profile from relatives, not from the people who run it.
- Projected roles see the privacy projection (ADR 0006): `shared` in full, `anonymous`
  redacted to time and status, `hidden` not at all.
- At most one grant per `(profile, grantee)`. The grantee can never be the owner. A
  `guardian` grant on a self profile is impossible. These rules are DB triggers, not only
  code (`profile_grants_guard`).

### 2. Access matrix

| Capability | owner (self) | owner (managed) | guardian | editor | viewer |
|---|---|---|---|---|---|
| Read profile (name, zone) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Read alert settings | ✓ | ✓ | ✓ | — | — |
| `shared` medications | full | full | full | full | full |
| `anonymous` medications | full | full | full | redacted | redacted |
| `hidden` medications | full | full | full | — | — |
| Write medications and schedules | all | all | all | `shared` only; `privacy` immutable; new ones `shared` | — |
| Record dose events (taken, skipped, snoozed, undo) | all | all | all | **—** | — |
| Edit profile, alert settings, privacy | ✓ | ✓ | ✓ | — | — |
| Invites and grants management | ✓ | ✓ | — | — | — |
| Delete profile | — (self is protected) | ✓ | — | — | — |
| Local reminders on own devices | ✓ | ✓ | ✓ (per-device toggle) | — | — |
| Missed-dose push | — (has local reminders) | ✓ | ✓ | ✓ (opt-out) | ✓ (opt-out) |
| Leave (delete own grant) | — | — | ✓ | ✓ | ✓ |

**D3 — editors do not mark doses.** "View+edit" means helping maintain the medication list
and schedules (a daughter fixing her father's new prescription), not confirming intakes on
someone's behalf. A dose mark is a statement that the person took the medicine; only the
person (owner) or the people who physically give it (guardians of a managed profile) can
make it. Dose events from an editor are rejected with `forbidden` (`rejected/forbidden` in
sync push) on any medication the editor can see, and with `not_found` on hidden or unknown
ones (no oracle). The app shows editors no mark buttons.

Relatives (`editor`, `viewer`) read and write only through sync (ADR 0006); the REST
resource endpoints stay limited to full-access roles, and a projected role gets 404 there.
That keeps the projected surface to one code path.

### 3. Grant lifecycle

- A grant is created only by accepting an invite (ADR 0009): never offline, so its id is
  server-generated. `invite_id` keeps provenance without an FK (invites are purged).
- The owner may change the role (`PATCH /v1/grants/{id}` `role`); the grantee may change
  `notify_missed`. Anyone else gets 404.
- Revocation (by the owner) and leaving (by the grantee) are a hard DELETE. No history of
  who was linked is kept (minimization). Devices learn about it from the scope list on the
  next pull and evict the scope's data (ADR 0006).
- A new grant does not flood the grantee with old missed-dose alerts: alert recipients
  are grants created before the occurrence was due (ADR 0007).
- The owner gets a `link_accepted` push when an invite is accepted, so unexpected access
  can be revoked at once.
- A grant is **active** only while neither its grantee nor the profile's owner is in
  `pending_deletion` (ADR 0010). Inactive grants are kept so a restore brings them back,
  but give no access and no alerts. This is part of the access predicate, not a stored flag.

### 4. Invites (summary; details in ADR 0009)

- Created by the owner for one profile and one role (`guardian` only on managed profiles).
- Single use, 7-day TTL, at most 5 active per profile; the token is shown once and stored
  only as `sha256`.
- The invitee previews (inviter, profile name and kind, role) and confirms; acceptance is
  idempotent per user.
- Expired, consumed or revoked invites are deleted 30 days after the end of their life.

### 5. Managed guardianship and the archive (D1)

A managed profile is owned by its primary guardian and may have co-guardians. Every
guardian gets local reminders on the devices where "remind on this device" is on, marks
doses, edits medications and schedules, and receives missed-dose alerts. Only the owner
manages invites and grants and may delete the profile.

**When the owner's account goes away** (deletion request, ADR 0010), the managed profile
becomes a **read-only archive** for its co-guardians:

- `profiles.archived_at` and `profiles.archive_reason` are set (server-controlled; CHECK:
  only on managed profiles, both columns set or both null);
- reminders stop on every device (the scope is sent with `archived: true`, ADR 0006) and
  the missed-dose detector skips the profile (ADR 0007);
- every write is rejected with `read_only` (REST `409`, sync `rejected/read_only`), for
  the owner and guardians alike; new invites and grants are refused (DB guard triggers);
- co-guardians keep reading the history: Today, History and the PDF report;
- any co-guardian may delete the archive (tombstone the profile, which evicts it from all
  devices); guardians may also leave;
- viewer and editor grants on the profile are inactive while the archive reason is
  `owner_pending_deletion`, and are deleted when it becomes `owner_erased`.

Reasons:

| `archive_reason` | Set when | Reversible |
|---|---|---|
| `owner_pending_deletion` | the owner requests account deletion | yes: a restore un-archives |
| `owner_erased` | the owner is hard-erased after the grace period | no (follow-up) |

At the hard erase, ownership of each archived profile moves to the **earliest co-guardian**
(`ORDER BY grant.created_at, grant.id`), that guardian's grant is deleted (they are now
the owner), and the archive survives the erasure of the former owner. If a managed profile
has no co-guardians, it is erased with the owner's data. The deletion dialog in the app
says which of the two happens to each managed profile.

Retaining the archive is justified because its data is about the managed person, not the
deleted user, and the co-guardians already had full access to it. The transfer keeps the
journal scope (keyed by profile, ADR 0006) and takes the journal locks of both owners.

### 6. Soft limits behind a flag

TZ §5 "лимиты под флагом": `FEATURE_SOFT_LIMITS` (default off), `SOFT_LIMIT_RELATIVES` (3,
counted as active grants on the owner's profiles) and `SOFT_LIMIT_PDF_REPORTS`. With the
flag on, accepting an invite beyond the limit fails with `409 relatives_limit_reached`.
`GET /v1/me/features` tells the app what to gate. With the flag off nothing is limited and
nothing is shown.

## Consequences

- New tables `profile_grants` and `invites`; `profiles` gains `archived_at` and
  `archive_reason` (`docs/phase3-plan.md`, data model). All of them are covered by the
  erasure transaction and the table inventory test.
- `app/services/access.py` is the single place that answers "which role does this user
  have on this profile" and "which profiles may this user see"; every loader and the
  scoped pull use it.
- The access predicate has three terms beyond ownership: grant exists, grant is active
  (no `pending_deletion` on either side), and for archived profiles only owner and guardian
  roles qualify.
- Editors cannot help with marking. If that turns out to be needed (for example a nurse),
  it would be a new role, not a change to `editor`.
- An archive can no longer be turned back into an active profile after `owner_erased`;
  that is a follow-up if owners ask for it.

## Alternatives considered

- **ACL per medication** instead of per profile: more flexible, but the privacy levels
  already express what relatives see per medication, and per-medication grants would
  multiply invite flows and UI.
- **Editors may mark `shared` doses** (the planner's default before D3): rejected by the
  owner; a mark is a statement by the person or their carer.
- **Transfer the managed profile to a co-guardian at once on the deletion request**
  (instead of an archive): the owner could not restore cleanly, and a profile could change
  owners without that person's action. The archive keeps the decision reversible during
  the grace period.
- **Erase managed profiles with the owner always**: loses grandma's history for the other
  guardians, who are the ones giving her the medicine.
- **A separate `guardianships` table**: managed profiles already exist; co-guardians are
  grants with a role, so one table and one access predicate suffice.
