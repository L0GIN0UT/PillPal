"""REST CRUD for profiles, medications, schedules and dose events.

All ids are client-generated UUIDs (offline creation). Foreign or missing ids
yield 404 - access is enforced inside every query, and REST is open to the
full-access roles only: the owner and the guardians of a managed profile.
Editors and viewers read and write through sync (ADR 0006), so for REST they
look like strangers. Every write route first locks the journal of the scope's
owner (``app.services.scopes``).
"""

from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import APIRouter, Query, Response, status
from pydantic import AwareDatetime, ValidationError

from app.deps import (
    CurrentUser,
    MedicationScope,
    MedicationScopeLock,
    OptionalDeviceId,
    OwnScopeLock,
    ProfileScope,
    ProfileScopeLock,
    ScheduleScope,
    SessionDep,
)
from app.errors import AppError, not_found, request_validation_error
from app.schemas.entities import (
    DoseEventCreate,
    DoseEventList,
    DoseEventOut,
    MedicationCreate,
    MedicationFields,
    MedicationList,
    MedicationOut,
    MedicationUpdate,
    ProfileCreate,
    ProfileList,
    ProfileOut,
    ProfileUpdate,
    ScheduleCreate,
    ScheduleList,
    ScheduleOut,
    ScheduleUpdate,
)
from app.services import dose_events as events
from app.services import entities as svc
from app.services.rules import canonical_rule_or_422
from app.services.scopes import lock_for_medication

router = APIRouter(prefix="/v1", tags=["resources"])

NO_CONTENT = status.HTTP_204_NO_CONTENT
MEDICATION_FIELDS = tuple(MedicationFields.model_fields)


def _medication_out(row: object) -> MedicationOut:
    return MedicationOut.model_validate(row)


# --- profiles -----------------------------------------------------------------


@router.get("/profiles", tags=["profiles"])
async def list_profiles(user: CurrentUser, session: SessionDep) -> ProfileList:
    rows = await svc.list_profiles(session, user.id)
    return ProfileList(items=[ProfileOut.model_validate(r) for r in rows])


@router.post(
    "/profiles",
    status_code=status.HTTP_201_CREATED,
    tags=["profiles"],
    dependencies=[OwnScopeLock],
)
async def create_profile(
    body: ProfileCreate, user: CurrentUser, session: SessionDep, device: OptionalDeviceId = None
) -> ProfileOut:
    ctx = svc.WriteContext.server(user.id, device)
    row = await svc.create_profile(
        session,
        ctx,
        profile_id=body.id,
        display_name=body.display_name,
        timezone=body.timezone,
        missed_alert_minutes=body.missed_alert_minutes,
        missed_alerts_enabled=body.missed_alerts_enabled,
    )
    await session.commit()
    return ProfileOut.model_validate(row)


@router.get("/profiles/{profile_id}", tags=["profiles"])
async def get_profile(profile_id: uuid.UUID, user: CurrentUser, session: SessionDep) -> ProfileOut:
    row = await svc.load_profile(session, user.id, profile_id)
    if row is None:
        raise not_found()
    return ProfileOut.model_validate(row)


@router.patch("/profiles/{profile_id}", tags=["profiles"], dependencies=[ProfileScopeLock])
async def update_profile(
    profile_id: uuid.UUID,
    body: ProfileUpdate,
    user: CurrentUser,
    session: SessionDep,
    device: OptionalDeviceId = None,
) -> ProfileOut:
    row = await svc.load_profile(session, user.id, profile_id, lock="update")
    if row is None:
        raise not_found()
    changes = body.model_dump(exclude_unset=True, exclude_none=True)
    if changes:
        ctx = svc.WriteContext.server(user.id, device).for_row(row.client_updated_at)
        await svc.update_profile(session, ctx, row, changes)
        await session.commit()
    return ProfileOut.model_validate(row)


@router.delete("/profiles/{profile_id}", status_code=NO_CONTENT, tags=["profiles"])
async def delete_profile(
    profile_id: uuid.UUID,
    scope: ProfileScope,
    user: CurrentUser,
    session: SessionDep,
    device: OptionalDeviceId = None,
) -> Response:
    """Delete a managed profile: only its owner (the primary guardian) may (ADR 0005)."""
    row = await svc.load_profile(session, user.id, profile_id, include_deleted=True, lock="update")
    if row is None:
        raise not_found()
    if scope.role != "owner":
        raise AppError(403, "forbidden", "Only the owner can delete this profile")
    if row.deleted_at is None:
        ctx = svc.WriteContext.server(user.id, device).for_row(row.client_updated_at)
        await svc.delete_profile(session, ctx, row)
        await session.commit()
    return Response(status_code=NO_CONTENT)


# --- medications --------------------------------------------------------------


@router.get("/profiles/{profile_id}/medications", tags=["medications"])
async def list_medications(
    profile_id: uuid.UUID, user: CurrentUser, session: SessionDep
) -> MedicationList:
    if await svc.load_profile(session, user.id, profile_id) is None:
        raise not_found()
    rows = await svc.list_medications(session, user.id, profile_id)
    return MedicationList(items=[_medication_out(r) for r in rows])


@router.post(
    "/profiles/{profile_id}/medications",
    status_code=status.HTTP_201_CREATED,
    tags=["medications"],
    dependencies=[ProfileScopeLock],
)
async def create_medication(
    profile_id: uuid.UUID,
    body: MedicationCreate,
    user: CurrentUser,
    session: SessionDep,
    device: OptionalDeviceId = None,
) -> MedicationOut:
    # FOR SHARE: a concurrent delete of the profile cannot slip past this insert.
    if await svc.load_profile(session, user.id, profile_id, lock="share") is None:
        raise not_found()
    ctx = svc.WriteContext.server(user.id, device)
    row = await svc.create_medication(
        session,
        ctx,
        medication_id=body.id,
        profile_id=profile_id,
        fields=body.model_dump(include=set(MEDICATION_FIELDS)),
    )
    await session.commit()
    return _medication_out(row)


@router.get("/medications/{medication_id}", tags=["medications"])
async def get_medication(
    medication_id: uuid.UUID, user: CurrentUser, session: SessionDep
) -> MedicationOut:
    row = await svc.load_medication(session, user.id, medication_id)
    if row is None:
        raise not_found()
    return _medication_out(row)


@router.patch(
    "/medications/{medication_id}", tags=["medications"], dependencies=[MedicationScopeLock]
)
async def update_medication(
    medication_id: uuid.UUID,
    body: MedicationUpdate,
    user: CurrentUser,
    session: SessionDep,
    device: OptionalDeviceId = None,
) -> MedicationOut:
    row = await svc.load_medication(session, user.id, medication_id, lock="update")
    if row is None:
        raise not_found()
    changes = body.model_dump(exclude_unset=True)
    if changes:
        current = {f: getattr(row, f) for f in MEDICATION_FIELDS}
        try:
            merged = MedicationFields.model_validate({**current, **changes})
        except ValidationError as exc:
            raise request_validation_error(exc, ("body",)) from None
        ctx = svc.WriteContext.server(user.id, device).for_row(row.client_updated_at)
        await svc.update_medication(session, ctx, row, merged.model_dump())
        await session.commit()
    return _medication_out(row)


@router.delete(
    "/medications/{medication_id}",
    status_code=NO_CONTENT,
    tags=["medications"],
    dependencies=[MedicationScopeLock],
)
async def delete_medication(
    medication_id: uuid.UUID,
    user: CurrentUser,
    session: SessionDep,
    device: OptionalDeviceId = None,
) -> Response:
    row = await svc.load_medication(
        session, user.id, medication_id, include_deleted=True, lock="update"
    )
    if row is None:
        raise not_found()
    if row.deleted_at is None:
        ctx = svc.WriteContext.server(user.id, device).for_row(row.client_updated_at)
        await svc.delete_medication(session, ctx, row)
        await session.commit()
    return Response(status_code=NO_CONTENT)


# --- schedules ----------------------------------------------------------------


@router.get("/medications/{medication_id}/schedules", tags=["schedules"])
async def list_schedules(
    medication_id: uuid.UUID, user: CurrentUser, session: SessionDep
) -> ScheduleList:
    if await svc.load_medication(session, user.id, medication_id) is None:
        raise not_found()
    rows = await svc.list_schedules(session, user.id, medication_id)
    return ScheduleList(items=[ScheduleOut.model_validate(r) for r in rows])


@router.post(
    "/medications/{medication_id}/schedules",
    status_code=status.HTTP_201_CREATED,
    tags=["schedules"],
)
async def create_schedule(
    medication_id: uuid.UUID,
    body: ScheduleCreate,
    scope: MedicationScope,
    user: CurrentUser,
    session: SessionDep,
    device: OptionalDeviceId = None,
) -> ScheduleOut:
    if await svc.load_medication(session, user.id, medication_id, lock="share") is None:
        raise not_found()
    rule = canonical_rule_or_422(body.rule)
    ctx = svc.WriteContext.server(user.id, device)
    row = await svc.create_schedule(
        session,
        ctx,
        schedule_id=body.id,
        profile_id=scope.profile_id,
        medication_id=medication_id,
        rule=rule,
    )
    await session.commit()
    return ScheduleOut.model_validate(row)


@router.get("/schedules/{schedule_id}", tags=["schedules"])
async def get_schedule(
    schedule_id: uuid.UUID, user: CurrentUser, session: SessionDep
) -> ScheduleOut:
    row = await svc.load_schedule(session, user.id, schedule_id)
    if row is None:
        raise not_found()
    return ScheduleOut.model_validate(row)


@router.patch("/schedules/{schedule_id}", tags=["schedules"])
async def update_schedule(
    schedule_id: uuid.UUID,
    body: ScheduleUpdate,
    scope: ScheduleScope,
    user: CurrentUser,
    session: SessionDep,
    device: OptionalDeviceId = None,
) -> ScheduleOut:
    row = await svc.load_schedule(session, user.id, schedule_id, lock="update")
    if row is None:
        raise not_found()
    rule = canonical_rule_or_422(body.rule)
    ctx = svc.WriteContext.server(user.id, device).for_row(row.client_updated_at)
    await svc.update_schedule(session, ctx, row, scope.profile_id, rule)
    await session.commit()
    return ScheduleOut.model_validate(row)


@router.delete("/schedules/{schedule_id}", status_code=NO_CONTENT, tags=["schedules"])
async def delete_schedule(
    schedule_id: uuid.UUID,
    scope: ScheduleScope,
    user: CurrentUser,
    session: SessionDep,
    device: OptionalDeviceId = None,
) -> Response:
    row = await svc.load_schedule(
        session, user.id, schedule_id, include_deleted=True, lock="update"
    )
    if row is None:
        raise not_found()
    if row.deleted_at is None:
        ctx = svc.WriteContext.server(user.id, device).for_row(row.client_updated_at)
        await svc.delete_schedule(session, ctx, row, scope.profile_id)
        await session.commit()
    return Response(status_code=NO_CONTENT)


# --- dose events (append-only: no update, no delete) ---------------------------


@router.post(
    "/dose-events",
    status_code=status.HTTP_201_CREATED,
    tags=["dose-events"],
    responses={
        200: {"model": DoseEventOut, "description": "Identical event already recorded"},
        409: {"description": "Different event with the same id exists"},
    },
)
async def create_dose_event(
    body: DoseEventCreate,
    response: Response,
    user: CurrentUser,
    session: SessionDep,
    device: OptionalDeviceId = None,
) -> DoseEventOut:
    await lock_for_medication(session, user.id, body.medication_id)
    row, created = await events.record_dose_event(session, user.id, device, body.id, body)
    if created:
        await session.commit()
    else:
        response.status_code = status.HTTP_200_OK
    return DoseEventOut.model_validate(row)


@router.get("/dose-events", tags=["dose-events"])
async def list_dose_events(
    user: CurrentUser,
    session: SessionDep,
    profile_id: uuid.UUID | None = None,
    medication_id: uuid.UUID | None = None,
    since: Annotated[AwareDatetime | None, Query(alias="from")] = None,
    until: Annotated[AwareDatetime | None, Query(alias="to")] = None,
    limit: Annotated[int, Query(ge=1, le=500)] = 100,
) -> DoseEventList:
    """Newest first. Full history is replicated through /v1/sync/pull."""
    rows = await events.list_dose_events(
        session,
        user.id,
        profile_id=profile_id,
        medication_id=medication_id,
        since=since,
        until=until,
        limit=limit,
    )
    return DoseEventList(items=[DoseEventOut.model_validate(r) for r in rows])


@router.get("/dose-events/{event_id}", tags=["dose-events"])
async def get_dose_event(
    event_id: uuid.UUID, user: CurrentUser, session: SessionDep
) -> DoseEventOut:
    row = await events.load_dose_event(session, user.id, event_id)
    if row is None:
        raise not_found()
    return DoseEventOut.model_validate(row)
