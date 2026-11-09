"""Bearer authentication of the private listener: ingest tokens (one per region) and admin tokens.

The catalog stores SHA-256 digests only (``catalog.config``); a presented secret is hashed and
compared in constant time (``catalog.tokens``). A missing, malformed or unknown secret is always
the same ``401``. A valid ingest token used for another region than its own is ``403``.
"""

from __future__ import annotations

import re
from collections.abc import Sequence

from fastapi import Depends, Request

from catalog.config import Settings, TokenEntry
from catalog.errors import AppError
from catalog.ratelimit import rate_limited
from catalog.tokens import match_token

# ``ru``, ``eu`` or a rotation variant such as ``ru-next`` / ``eu_2``.
_REGION_PREFIX = re.compile(r"^[a-z0-9]+")
_BEARER = re.compile(r"^Bearer ([^\s]{1,512})$")


def token_region(entry: TokenEntry) -> str:
    """The region an ingest token speaks for: the part of its name before ``-`` or ``_``."""
    found = _REGION_PREFIX.match(entry.name)
    return found.group(0) if found else ""


def _unauthorized() -> AppError:
    return AppError(
        401,
        "unauthorized",
        "Authentication required",
        headers={"WWW-Authenticate": "Bearer"},
    )


def authenticate(request: Request, entries: Sequence[TokenEntry]) -> TokenEntry:
    found = _BEARER.match(request.headers.get("authorization", ""))
    matched = match_token(found.group(1), entries) if found else None
    if matched is None:
        raise _unauthorized()
    return matched


async def require_ingest(request: Request) -> TokenEntry:
    settings: Settings = request.app.state.settings
    return authenticate(request, settings.ingest_tokens)


async def require_admin(request: Request) -> TokenEntry:
    settings: Settings = request.app.state.settings
    return authenticate(request, settings.admin_tokens)


# Rate limiting runs before authentication, so guessing is throttled like any other request.
INGEST_DEPENDENCIES = [Depends(rate_limited)]
ADMIN_DEPENDENCIES = [Depends(rate_limited), Depends(require_admin)]
