"""Bearer authentication of the private listener: ingest tokens (one per region) and admin tokens.

The catalog stores SHA-256 digests only (``catalog.config``); a presented secret is hashed and
compared in constant time (``catalog.tokens``). A missing, malformed or unknown secret is always
the same ``401``. A valid ingest token used for another region than its own is ``403``.
"""

from __future__ import annotations

import re
from collections.abc import Sequence
from typing import Any

from fastapi import Depends, Request

from catalog.config import Settings, TokenEntry
from catalog.errors import AppError
from catalog.ratelimit import RateLimiter
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


def _client_ip(request: Request) -> str:
    return request.client.host if request.client else "unknown"


async def authenticate(request: Request, entries: Sequence[TokenEntry]) -> TokenEntry:
    """Authenticate, then throttle by who was authenticated.

    A failed attempt counts against the caller IP (a low limit: guessing is throttled), a valid
    one against its token (a high limit: a large snapshot is many pages). A valid caller is
    therefore never blocked by the address limit, and an attacker never gets a token bucket.
    """
    limiter: RateLimiter = request.app.state.rate_limiter
    settings: Settings = request.app.state.settings
    found = _BEARER.match(request.headers.get("authorization", ""))
    matched = match_token(found.group(1), entries) if found else None
    if matched is None:
        await limiter.failed_auth(_client_ip(request))
        raise _unauthorized()
    await limiter.check_one("private-token", matched.name, settings.private_rate_limit_token_max)
    return matched


async def require_ingest(request: Request) -> TokenEntry:
    settings: Settings = request.app.state.settings
    return await authenticate(request, settings.ingest_tokens)


async def require_admin(request: Request) -> TokenEntry:
    settings: Settings = request.app.state.settings
    return await authenticate(request, settings.admin_tokens)


INGEST_DEPENDENCIES: list[Any] = []
ADMIN_DEPENDENCIES = [Depends(require_admin)]
