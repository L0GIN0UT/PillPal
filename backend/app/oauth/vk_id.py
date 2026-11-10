"""VK ID: the authorization-code verifier (ADR 0017 section 3). Android, RU only.

The app runs the authorization with PKCE and sends the server only the code, the verifier, the
``device_id`` VK returned with the code and the server-issued ``state``; the server trades them at
``id.vk.ru/oauth2/auth`` and then reads the user at ``/oauth2/user_info``. A VK access token from
the client is never accepted: the only client value is exchanged as a code.

VK ``user_info`` carries an ``email`` with the ``email`` scope, but the VK documentation does not
call it verified (its ``verified`` field is the blue check mark of well-known people), so it never
counts: the sign-up goes through the mailed-code fallback. The app is confidential on our side:
the client secret setting is the application service key, sent as ``service_token``.
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

VK_TOKEN_URL = "https://id.vk.ru/oauth2/auth"  # noqa: S105 (an endpoint, not a secret)
VK_USER_INFO_URL = "https://id.vk.ru/oauth2/user_info"
VK_PLATFORM = "android"


def vk_redirect_uri(settings: Settings) -> str | None:
    """The redirect URI of the authorization (the VK Android default: ``vk<client id>://vk.ru/...``).

    Configured on the server, not taken from the client: it must equal the one the app used and
    VK checks it against the registered list.
    """
    if settings.oauth_vk_redirect_uri:
        return settings.oauth_vk_redirect_uri
    if settings.oauth_vk_client_id:
        return f"vk{settings.oauth_vk_client_id}://vk.ru/blank.html"
    return None


class VkIdProvider:
    name = "vk_id"
    # The ``state`` is the server nonce (purpose-bound, single use, spent before the exchange).
    uses_nonce = True

    def __init__(self, settings: Settings, http: httpx.AsyncClient) -> None:
        self._client_id = settings.oauth_vk_client_id
        secret = settings.oauth_vk_client_secret
        self._secret = secret.get_secret_value() if secret is not None else None
        self._redirect_uri = vk_redirect_uri(settings)
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
        client_id, secret, redirect_uri = self._client_id, self._secret, self._redirect_uri
        if (
            platform != VK_PLATFORM
            or not client_id
            or not secret
            or not redirect_uri
            or not assertion
            or not nonce
            or not code_verifier
            or not device_id
        ):
            raise invalid_provider_token()
        tokens = await call_json(
            self._http,
            "POST",
            VK_TOKEN_URL,
            data={
                "grant_type": "authorization_code",
                "code": assertion,
                "code_verifier": code_verifier,
                "redirect_uri": redirect_uri,
                "client_id": client_id,
                "device_id": device_id,
                "state": nonce,
                "service_token": secret,
            },
        )
        access_token = text_value(tokens.get("access_token"))
        # VK echoes the state; a different one means the answer is not for this authorization.
        if access_token is None or tokens.get("state", nonce) != nonce:
            raise invalid_provider_token()
        info = await call_json(
            self._http,
            "POST",
            VK_USER_INFO_URL,
            data={"client_id": client_id, "access_token": access_token},
        )
        user = info.get("user")
        if not isinstance(user, dict):
            raise invalid_provider_token()
        subject = subject_of(user.get("user_id"))
        exchanged = tokens.get("user_id")
        if subject is None or (exchanged is not None and subject_of(exchanged) != subject):
            raise invalid_provider_token()
        return code_identity(
            self.name,
            assertion,
            subject=subject,
            email=normalized_email(user.get("email")),
            now=now,
        )
