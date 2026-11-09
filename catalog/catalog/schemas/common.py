"""Types shared by the public schemas."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict

Market = Literal["ru", "us", "eu"]
Lang = Literal["ru", "en"]


class RequestModel(BaseModel):
    """Inputs reject unknown fields (security rule: Pydantic at the boundary, extra=forbid)."""

    model_config = ConfigDict(extra="forbid")
