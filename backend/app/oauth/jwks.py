"""A cached JWKS of an ID-token provider (ADR 0017 section 3).

Keys are fetched over HTTPS with the shared client (timeout ``OAUTH_HTTP_TIMEOUT_SECONDS``, answer
size bounded), kept for ``OAUTH_JWKS_CACHE_SECONDS`` and refreshed once when a token names an
unknown ``kid`` (key rotation).

* A refresh is refused inside the cooldown after the previous fetch, so a flood of tokens with
  random ``kid`` values cannot turn this server into a request amplifier.
* A failed fetch is remembered: for the cooldown nothing is fetched again (fail fast), and after
  the TTL the previous keys keep serving for ``OAUTH_JWKS_STALE_SECONDS`` so a provider outage does
  not lock everybody out. With no usable keys the answer is ``provider_unreachable``.

The caller passes ``now``: the cache has no clock of its own. Redirects are not followed, keys that
are not for signatures (``use`` other than ``sig``) or not RSA/EC are skipped. Nothing is logged.
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
MAX_JWKS_BYTES = 262_144  # the real documents are a few KiB


class JwksCache:
    def __init__(
        self,
        url: str,
        http: httpx.AsyncClient,
        *,
        ttl_seconds: int,
        refresh_cooldown_seconds: int,
        stale_seconds: int = 0,
    ) -> None:
        self._url = url
        self._http = http
        self._ttl = timedelta(seconds=ttl_seconds)
        self._cooldown = timedelta(seconds=refresh_cooldown_seconds)
        self._stale = timedelta(seconds=stale_seconds)
        self._keys: dict[str, PyJWK] = {}
        self._fetched_at: datetime | None = None
        self._failed_at: datetime | None = None
        self._lock = asyncio.Lock()  # concurrent misses share one fetch

    async def key_for(self, kid: str, now: datetime) -> PyJWK | None:
        """The signing key named ``kid``, or ``None`` when the provider does not publish it.

        Raises ``provider_unreachable`` when there are no usable keys and none can be fetched.
        """
        async with self._lock:
            fetched_now = False
            if self._fetched_at is None or now - self._fetched_at >= self._ttl:
                fetched_now = await self._refresh(now)
                if not fetched_now and not self._serviceable(now):
                    raise provider_unreachable()
            key = self._keys.get(kid)
            if key is None and not fetched_now and self._may_refresh_for_new_kid(now):
                await self._refresh(now)
                key = self._keys.get(kid)
            return key

    def _serviceable(self, now: datetime) -> bool:
        """Whether the previous keys may still be used (within the stale window)."""
        return (
            bool(self._keys)
            and self._fetched_at is not None
            and now - self._fetched_at < self._ttl + self._stale
        )

    def _may_refresh_for_new_kid(self, now: datetime) -> bool:
        return self._fetched_at is None or now - self._fetched_at >= self._cooldown

    async def _refresh(self, now: datetime) -> bool:
        """Fetch the keys; ``False`` when that failed or is held back by the failure cooldown."""
        if self._failed_at is not None and now - self._failed_at < self._cooldown:
            return False
        try:
            keys = await self._fetch()
        except (httpx.HTTPError, ValueError):
            self._failed_at = now
            return False
        self._keys, self._fetched_at, self._failed_at = keys, now, None
        return True

    async def _fetch(self) -> dict[str, PyJWK]:
        response = await self._http.get(self._url)
        response.raise_for_status()
        declared = response.headers.get("content-length")
        if len(response.content) > MAX_JWKS_BYTES or (
            declared is not None and declared.isdigit() and int(declared) > MAX_JWKS_BYTES
        ):
            raise ValueError("too large")
        document = response.json()
        if not isinstance(document, dict) or not isinstance(document.get("keys"), list):
            raise ValueError("not a key set")
        return _usable_keys(document["keys"])


def _usable_keys(entries: list[Any]) -> dict[str, PyJWK]:
    keys: dict[str, PyJWK] = {}
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("kid"), str):
            continue
        if entry.get("kty") not in ASYMMETRIC_KEY_TYPES:
            continue  # never a shared secret (``oct``) from a key set
        if "use" in entry and entry["use"] != "sig":
            continue  # an encryption key does not verify signatures
        try:
            keys[entry["kid"]] = PyJWK.from_dict(entry)
        except (PyJWTError, ValueError, TypeError, KeyError):
            continue  # a key type this server does not use must not hide the others
    return keys
