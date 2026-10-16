"""/v1/sync/push and /v1/sync/pull (TZ §4.3)."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Query

from app.deps import CurrentUser, RequiredDeviceId, SessionDep
from app.schemas.entities import MAX_PULL_LIMIT, PullResponse, PushRequest, PushResponse
from app.services.sync import SyncService

router = APIRouter(prefix="/v1/sync", tags=["sync"])


@router.post("/push")
async def push(
    body: PushRequest, user: CurrentUser, session: SessionDep, device_id: RequiredDeviceId
) -> PushResponse:
    """Apply a batch of mutations; one result per mutation, in order.

    ``applied`` - stored (or an idempotent replay of a stored write);
    ``ignored_stale`` - the server already has a newer write or a tombstone;
    ``rejected`` - invalid, see ``code``. Replaying a whole batch is safe.
    """
    results = await SyncService(session, user.id, device_id).push(body.mutations)
    return PushResponse(results=results)


@router.get("/pull")
async def pull(
    user: CurrentUser,
    session: SessionDep,
    cursor: Annotated[int, Query(ge=0)] = 0,
    limit: Annotated[int, Query(ge=1, le=MAX_PULL_LIMIT)] = 100,
) -> PullResponse:
    """Changes after ``cursor`` with the current state of each entity."""
    return await SyncService(session, user.id, "").pull(cursor, limit)
