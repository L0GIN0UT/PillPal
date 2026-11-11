"""``GET /v1/config`` (milestone 5.12): the same for every account, nothing medical."""

from __future__ import annotations

from pydantic import BaseModel


class AdPlacementOut(BaseModel):
    unit_id: str


class AdsConfigOut(BaseModel):
    # Screen name (allowlist of ADR 0018 section 2) -> placement.
    placements: dict[str, AdPlacementOut]


class RemoteConfigOut(BaseModel):
    ads: AdsConfigOut
