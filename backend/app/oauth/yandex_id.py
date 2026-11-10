"""Yandex ID: the authorization-code verifier (ADR 0017 section 3). Android, RU only.

The app runs the authorization with PKCE and sends the server only the code, the verifier and the
server-issued ``state``; the server trades them at ``oauth.yandex.ru/token`` and reads the user at
``login.yandex.ru/info``. A Yandex access token from the client is never accepted.

``default_email`` needs the ``login:email`` right; the Yandex documentation does not call it
verified, so it never counts and the sign-up goes through the mailed-code fallback. The user
request carries the token in the ``Authorization`` header, never in the URL.

Yandex does not echo or bind ``state`` to the code at the token endpoint, so the binding is PKCE
plus the app-side state check; the server only spends its own state (purpose, single use).
A retry after any failure needs a new code AND a new state (both are spent).
"""

from __future__ import annotations

from datetime import datetime

import httpx

from app.config import Settings
from app.oauth.base import VerifiedIdentity
from app.oauth.code_http import (
    call_json,
    code_identity,
    normalized_email,
    subject_of,
    text_value,
)
from app.oauth.errors import invalid_provider_token

YANDEX_TOKEN_URL = "https://oauth.yandex.ru/token"  # noqa: S105 (an endpoint, not a secret)
YANDEX_INFO_URL = "https://login.yandex.ru/info"
YANDEX_PLATFORM = "android"


class YandexIdProvider:
    name = "yandex_id"
    uses_nonce = True

    def __init__(self, settings: Settings, http: httpx.AsyncClient) -> None:
        self._client_id = settings.oauth_yandex_client_id
        secret = settings.oauth_yandex_client_secret
        self._secret = secret.get_secret_value() if secret is not None else None
        self._http = http

    async def verify(
        self,
        assertion: str,
        *,
        nonce: str | None,
        platform: str,
        code_verifier: str | None,
        now: datetime,
        device_id: str | None = None,
    ) -> VerifiedIdentity:
        client_id, secret = self._client_id, self._secret
        if (
            platform != YANDEX_PLATFORM
            or not client_id
            or not secret
            or not assertion
            or not nonce
            or not code_verifier
        ):
            raise invalid_provider_token()
        tokens = await call_json(
            self._http,
            "POST",
            YANDEX_TOKEN_URL,
            data={
                "grant_type": "authorization_code",
                "code": assertion,
                "code_verifier": code_verifier,
                "client_id": client_id,
                "client_secret": secret,
            },
        )
        access_token = text_value(tokens.get("access_token"))
        if access_token is None:
            raise invalid_provider_token()
        user = await call_json(
            self._http,
            "GET",
            YANDEX_INFO_URL,
            headers={"Authorization": f"OAuth {access_token}"},
            params={"format": "json"},
        )
        subject = subject_of(user.get("id"))
        # The token came from the exchange just made, but the answer names its application
        # (documented standard field): required and equal.
        if subject is None or user.get("client_id") != client_id:
            raise invalid_provider_token()
        return code_identity(
            self.name,
            assertion,
            subject=subject,
            email=normalized_email(user.get("default_email")),
            now=now,
        )
