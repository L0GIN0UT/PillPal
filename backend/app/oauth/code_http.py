"""The HTTP side of the authorization-code providers (VK ID, Yandex ID; ADR 0017 section 3).

Every call goes through one rule set, so no provider can drift from it:

* a timeout, a transport error, a 5xx, a 429 or an error body that names a temporary condition is
  503 ``provider_unreachable`` (the user may retry with a new code);
* anything else that is not a plain 200 with a JSON object (a refusal, a spent code, a PKCE
  mismatch, a redirect, an oversized or unparsable body) is 401 ``invalid_provider_token``.

Nothing from a request or a response is put into an exception or a log: the code, the verifier,
the access token and the provider's error text stay in this frame.
"""

from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timedelta
from typing import Any

import httpx

from app.oauth.base import VerifiedIdentity
from app.oauth.errors import invalid_provider_token, provider_unreachable

MAX_RESPONSE_BYTES = 64 * 1024
MAX_SUBJECT_LENGTH = 255
MAX_EMAIL_LENGTH = 254
# Both providers give an authorization code 10 minutes to live (their documentation).
CODE_LIFETIME = timedelta(minutes=10)
# ``error`` values that mean "try again later", not "this code is bad".
TEMPORARY_ERRORS = frozenset({"server_error", "temporarily_unavailable", "slow_down"})
_EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


async def call_json(
    http: httpx.AsyncClient,
    method: str,
    url: str,
    *,
    data: dict[str, str] | None = None,
    headers: dict[str, str] | None = None,
) -> dict[str, Any]:
    """One provider call; the JSON object of a 200 answer, or the stable error."""
    try:
        response = await http.request(method, url, data=data, headers=headers)
    except httpx.HTTPError:
        raise provider_unreachable() from None
    body = _json_object(response)
    if response.status_code >= 500 or response.status_code == 429:
        raise provider_unreachable()
    if body is not None and body.get("error") in TEMPORARY_ERRORS:
        raise provider_unreachable()
    if response.status_code != 200 or body is None or body.get("error"):
        raise invalid_provider_token()
    return body


def _json_object(response: httpx.Response) -> dict[str, Any] | None:
    if len(response.content) > MAX_RESPONSE_BYTES:
        return None
    try:
        body = json.loads(response.content)
    except ValueError:
        return None
    return body if isinstance(body, dict) else None


def text_value(value: object, *, limit: int = 4096) -> str | None:
    """A non-empty string, or ``None`` (a number or a blank is not a token or an id here)."""
    return value if isinstance(value, str) and 0 < len(value) <= limit else None


def subject_of(value: object) -> str | None:
    """The provider's user id as text: a string or an integer, 1 to 255 characters."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        value = str(value)
    return text_value(value, limit=MAX_SUBJECT_LENGTH)


def normalized_email(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    email = value.strip().lower()
    return email if len(email) <= MAX_EMAIL_LENGTH and _EMAIL_RE.match(email) else None


def code_identity(
    provider: str, code: str, *, subject: str, email: str | None, now: datetime
) -> VerifiedIdentity:
    """The identity of an authorization code exchanged just now.

    ``email_verified`` is always false: neither provider's documentation says its address is
    verified, so the address goes through the mailed-code fallback (owner decision Q7). The code
    itself is single use, and only its hash feeds the replay set.
    """
    return VerifiedIdentity(
        provider=provider,
        subject=subject,
        email=email,
        email_verified=False,
        assertion_id=hashlib.sha256(code.encode()).hexdigest(),
        expires_at=now + CODE_LIFETIME,
        issued_at=now,
    )
