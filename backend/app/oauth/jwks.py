"""A cached JWKS of an ID-token provider (ADR 0017 section 3).

Keys are fetched over HTTPS with the shared client (timeout ``OAUTH_HTTP_TIMEOUT_SECONDS``),
kept for ``OAUTH_JWKS_CACHE_SECONDS`` and refreshed once when a token names an unknown ``kid``
(key rotation). A refresh is refused inside a short cooldown after the previous fetch, so a flood of
tokens with random ``kid`` values cannot turn this server into a request amplifier. The caller
passes ``now``: the cache has no clock of its own. Redirects are not followed. Nothing is logged.
"""

from __future__ import annotations

import asyncio
from datetime import datetime, timedelta
from typing import Any

import httpx
from jwt import PyJWK
from jwt.exceptions import PyJWTError

from app.oauth.errors import provider_unreachable

ASYMMETRIC_KEY_TYPES = ("RSA", "EC")


class JwksCache:
    def __init__(
        self,
        url: str,
        http: httpx.AsyncClient,
        *,
        ttl_seconds: int,
        refresh_cooldown_seconds: int,
    ) -> None:
        self._url = url
        self._http = http
        self._ttl = timedelta(seconds=ttl_seconds)
        self._cooldown = timedelta(seconds=refresh_cooldown_seconds)
        self._keys: dict[str, PyJWK] = {}
        self._fetched_at: datetime | None = None
        self._lock = asyncio.Lock()  # concurrent misses share one fetch

    async def key_for(self, kid: str, now: datetime) -> PyJWK | None:
        """The signing key named ``kid``, or ``None`` when the provider does not publish it.

        Raises ``provider_unreachable`` when the keys cannot be fetched.
        """
        async with self._lock:
            fetched_now = False
            if self._fetched_at is None or now - self._fetched_at >= self._ttl:
                await self._fetch(now)
                fetched_now = True
            key = self._keys.get(kid)
            if key is None and not fetched_now and self._may_refresh(now):
                await self._fetch(now)
                key = self._keys.get(kid)
            return key

    def _may_refresh(self, now: datetime) -> bool:
        return self._fetched_at is None or now - self._fetched_at >= self._cooldown

    async def _fetch(self, now: datetime) -> None:
        try:
            response = await self._http.get(self._url)
            response.raise_for_status()
            document = response.json()
        except (httpx.HTTPError, ValueError):
            raise provider_unreachable() from None
        if not isinstance(document, dict) or not isinstance(document.get("keys"), list):
            raise provider_unreachable()
        self._keys = _usable_keys(document["keys"])
        self._fetched_at = now


def _usable_keys(entries: list[Any]) -> dict[str, PyJWK]:
    keys: dict[str, PyJWK] = {}
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("kid"), str):
            continue
        if entry.get("kty") not in ASYMMETRIC_KEY_TYPES:
            continue  # never a shared secret (``oct``) from a key set
        try:
            keys[entry["kid"]] = PyJWK.from_dict(entry)
        except (PyJWTError, ValueError, TypeError, KeyError):
            continue  # a key type this server does not use must not hide the others
    return keys
