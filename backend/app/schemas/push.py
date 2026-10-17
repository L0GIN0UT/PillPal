"""Push token registration (ADR 0008 §1). The token is write-only: it is never returned."""

from __future__ import annotations

import re
from datetime import datetime
from typing import Self

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.push.base import (
    APNS_TOKEN_PATTERN,
    MAX_TOKEN_LENGTH,
    OPAQUE_TOKEN_PATTERN,
    ApnsEnvironment,
    PushProvider,
)

_APNS_TOKEN = re.compile(APNS_TOKEN_PATTERN)
_OPAQUE_TOKEN = re.compile(OPAQUE_TOKEN_PATTERN)


class PushTokenIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    provider: PushProvider
    token: str = Field(min_length=1, max_length=MAX_TOKEN_LENGTH)
    # Reported by the build (debug = sandbox); required for APNs, forbidden otherwise.
    apns_environment: ApnsEnvironment | None = None

    @model_validator(mode="after")
    def _format_matches_provider(self) -> Self:
        pattern = _APNS_TOKEN if self.provider == "apns" else _OPAQUE_TOKEN
        if not pattern.fullmatch(self.token):
            raise ValueError("token does not have the format of its provider")
        if (self.provider == "apns") != (self.apns_environment is not None):
            raise ValueError("apns_environment is required for apns and only for apns")
        return self


class PushTokenOut(BaseModel):
    provider: PushProvider
    apns_environment: ApnsEnvironment | None
    updated_at: datetime
