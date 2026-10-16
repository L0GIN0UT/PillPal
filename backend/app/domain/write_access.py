"""Who may write what through sync (ADR 0006 §6, owner decision D3): pure rules.

The caller loads the target row *without* an access filter, works out the role
and the privacy of the medication involved, and asks this module for a verdict
before last-write-wins runs. The verdict never depends on the payload beyond
``incoming_privacy``, so what a relative may do cannot be probed by crafting it.

For editors the first matching rule wins:

1. the entity, or its medication, is not fully visible to them (``hidden``,
   ``anonymous``, unknown) or is in no accessible scope: ``not_found``; a *delete*
   of such an entity (or of one that does not exist) is ``noop``, answered
   ``applied`` like a repeated delete, so deletes cannot probe for ids;
2. profile upsert or delete: ``read_only``;
3. a dose event of any type: ``forbidden``;
4. delete of a medication or schedule: ``forbidden``;
5. a medication upsert that changes ``privacy``, or a new one that is not
   ``shared``: ``forbidden_field``;
6. otherwise allowed (last-write-wins decides).

Viewers get rule 1, then ``forbidden`` for every write. Owner and guardian may
do everything, except that a guardian cannot delete a profile.
"""

from __future__ import annotations

from typing import Literal

from app.domain.privacy import Role, form_for, is_full_access

Verdict = Literal["allowed", "not_found", "noop", "forbidden", "read_only", "forbidden_field"]
WriteEntity = Literal["profile", "medication", "schedule", "dose_event"]
WriteOp = Literal["upsert", "delete"]

DEFAULT_NEW_MEDICATION_PRIVACY = "shared"


def check_write(
    role: Role | None,
    entity: WriteEntity,
    op: WriteOp,
    *,
    exists: bool,
    medication_privacy: str | None = None,
    incoming_privacy: str | None = None,
) -> Verdict:
    """The verdict for one write.

    ``medication_privacy`` is the privacy of the medication the entity is, or belongs
    to (``None`` for profiles and for a medication that does not exist yet);
    ``incoming_privacy`` is the privacy a medication upsert carries.
    """
    if op == "delete" and (role is None or not exists):
        return "noop"  # deleting what is not there (or not visible) is a quiet success
    if role is None:
        return "not_found"
    if is_full_access(role):
        # Kind-independent on purpose (a self profile cannot have a guardian anyway); an
        # archived profile will be the guardians' to handle in 3.4.
        if role == "guardian" and entity == "profile" and op == "delete":
            return "forbidden"
        return "allowed"
    if _invisible(entity, exists, medication_privacy, role):
        return "noop" if op == "delete" else "not_found"
    if role == "viewer":
        return "forbidden"
    return _editor_rules(entity, op, exists, medication_privacy, incoming_privacy)


def _invisible(entity: WriteEntity, exists: bool, privacy: str | None, role: Role) -> bool:
    if entity == "profile" or (entity == "medication" and not exists):
        return False
    return privacy is None or form_for(role, privacy) != "projected"


def _editor_rules(
    entity: WriteEntity,
    op: WriteOp,
    exists: bool,
    medication_privacy: str | None,
    incoming_privacy: str | None,
) -> Verdict:
    if entity == "profile":
        return "read_only"
    if entity == "dose_event" or op == "delete":
        return "forbidden"
    if entity == "medication":
        expected = medication_privacy if exists else DEFAULT_NEW_MEDICATION_PRIVACY
        if incoming_privacy != expected:
            return "forbidden_field"
    return "allowed"
