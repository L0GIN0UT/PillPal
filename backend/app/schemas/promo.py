"""``POST /v1/me/promo/redeem`` (ADR 0018 section 4)."""

from __future__ import annotations

from pydantic import BaseModel, ConfigDict, Field

from app.domain.promo import MAX_INPUT_LENGTH


class PromoRedeemIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    # What the person typed, with or without groups and case; checked and normalised by the
    # service. Never echoed in an error or logged.
    code: str = Field(min_length=1, max_length=MAX_INPUT_LENGTH, repr=False)
