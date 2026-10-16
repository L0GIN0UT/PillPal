"""The state of an entity as sync shows it: full for the owner, projected for relatives.

``entity_state`` is the representation shared by pull changes and the ``current``
of push results (TZ §4.3); ``project_state`` runs it through the privacy
projection (ADR 0006 §3) so no relative-facing output skips the projection.
"""

from __future__ import annotations

from typing import Any

from pydantic import BaseModel

from app.db.models import DoseEvent, Medication, Profile, Schedule
from app.domain.privacy import Role, form_for, is_full_access, project_change
from app.schemas.entities import (
    DoseEventOut,
    EntityState,
    MedicationOut,
    ProfileOut,
    ScheduleOut,
)

SyncRow = Profile | Medication | Schedule

_OUT_MODELS: dict[str, type[BaseModel]] = {
    "profile": ProfileOut,
    "medication": MedicationOut,
    "schedule": ScheduleOut,
}


def entity_state(entity: str, row: SyncRow | DoseEvent) -> EntityState:
    """Current state of ``row``; tombstones have ``data=None`` but keep the key."""
    if isinstance(row, DoseEvent):
        data = DoseEventOut.model_validate(row).model_dump(mode="json")
        return EntityState(
            op="upsert", data=data, client_updated_at=None, updated_by_device=None, deleted_at=None
        )
    deleted = row.deleted_at is not None
    return EntityState(
        op="delete" if deleted else "upsert",
        data=None if deleted else _OUT_MODELS[entity].model_validate(row).model_dump(mode="json"),
        client_updated_at=row.client_updated_at,
        updated_by_device=row.updated_by_device,
        deleted_at=row.deleted_at,
    )


def project_state(
    entity: str, state: EntityState, role: Role, medication_privacy: str | None
) -> EntityState | None:
    """``state`` as ``role`` may see it; ``None`` when the entity is not visible at all.

    ``medication_privacy`` is the privacy of the medication a medication, schedule or
    dose event is (or belongs to). It is checked before the payload, so a tombstone
    of a hidden medication's schedule is not visible either: its mere existence
    would reveal the hidden medication.
    """
    if is_full_access(role):
        return state
    if entity != "profile" and form_for(role, str(medication_privacy)) is None:
        return None
    change: dict[str, Any] = {"entity": entity, **state.model_dump()}
    projected = project_change(change, role, medication_privacy)
    if projected is None:  # pragma: no cover - the visibility check above already decided
        return None
    projected.pop("entity", None)
    return EntityState.model_validate(projected)
