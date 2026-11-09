"""Dependencies of every public ``/v1`` route (ADR 0011 section 2, ADR 0015 section 3)."""

from __future__ import annotations

from fastapi import Depends, Request, Response

from catalog.errors import AppError
from catalog.ratelimit import rate_limited


async def reject_authorization(request: Request) -> None:
    """The catalog takes no credentials: a client that sends one has a bug that could leak a
    backend token, so the request is refused instead of ignored."""
    if "authorization" in request.headers:
        raise AppError(400, "unexpected_authorization", "This service takes no credentials")


async def no_store(response: Response) -> None:
    """Lookups carry what a person searched for or scanned: nothing may keep a copy."""
    response.headers["Cache-Control"] = "no-store"


PUBLIC_DEPENDENCIES = [Depends(reject_authorization), Depends(rate_limited)]
LOOKUP_DEPENDENCIES = [*PUBLIC_DEPENDENCIES, Depends(no_store)]
