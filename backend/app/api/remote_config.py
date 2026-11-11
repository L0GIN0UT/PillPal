"""``GET /v1/config``: remote config for the app (milestone 5.12).

Authenticated, identical for every account (so a revalidating cache is safe) and validated ETag.
No clock or account data goes into the body: the ETag changes only when the settings do.
"""

from __future__ import annotations

import hashlib

from fastapi import APIRouter, Request, Response

from app.deps import CurrentUser, SettingsDep
from app.domain.remote_config import Platform, placements_for
from app.schemas.remote_config import AdPlacementOut, AdsConfigOut, RemoteConfigOut

router = APIRouter(prefix="/v1", tags=["config"])

CACHE_CONTROL = "private, no-cache"


def _etag(body: RemoteConfigOut) -> str:
    digest = hashlib.sha256(body.model_dump_json().encode()).hexdigest()
    return f'"{digest[:32]}"'


def _matches(if_none_match: str | None, etag: str) -> bool:
    if if_none_match is None:
        return False
    candidates = [part.strip().removeprefix("W/") for part in if_none_match.split(",")]
    return "*" in candidates or etag in candidates


@router.get(
    "/config", response_model=RemoteConfigOut, responses={304: {"description": "Not modified"}}
)
async def get_config(
    _: CurrentUser, settings: SettingsDep, request: Request, platform: Platform
) -> Response:
    placements = placements_for(settings.remote_config_ads, platform)
    body = RemoteConfigOut(
        ads=AdsConfigOut(placements={s: AdPlacementOut(unit_id=u) for s, u in placements.items()})
    )
    etag = _etag(body)
    headers = {"ETag": etag, "Cache-Control": CACHE_CONTROL}
    if _matches(request.headers.get("if-none-match"), etag):
        return Response(status_code=304, headers=headers)
    return Response(content=body.model_dump_json(), media_type="application/json", headers=headers)
