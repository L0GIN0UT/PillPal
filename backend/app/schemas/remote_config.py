"""``GET /v1/config`` (milestone 5.12): the same for every account, nothing medical."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel

Platform = Literal["android", "ios"]


class AdPlacementOut(BaseModel):
    unit_id: str


class AdsConfigOut(BaseModel):
    # Screen name (allowlist of ADR 0018 section 2) -> placement.
    placements: dict[str, AdPlacementOut]


class RemoteConfigOut(BaseModel):
    ads: AdsConfigOut
