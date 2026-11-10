"""Helpers of the VK ID and Yandex ID suites (milestone 5.9): the two providers' endpoints played
by ``httpx.MockTransport``. Every id, code, verifier and token here is synthetic."""

from __future__ import annotations

import urllib.parse
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

import httpx

from app.config import Settings
from app.oauth.vk_id import VK_TOKEN_URL, VK_USER_INFO_URL
from app.oauth.yandex_id import YANDEX_INFO_URL, YANDEX_TOKEN_URL
from tests.conftest import make_settings

NOW = datetime(2026, 11, 10, 12, 0, tzinfo=UTC)
STATE = "state-" + "s" * 37  # what ``POST /v1/auth/oauth/nonce`` returns, 43 characters
VERIFIER = "verifier-" + "v" * 40
CODE = "code.synthetic-authorization-code"
DEVICE_ID = "device-synthetic-0001"
ACCESS_TOKEN = "access.synthetic-token-value"
REFRESH_TOKEN = "refresh.synthetic-token-value"
VK_CLIENT_ID = "5551234"
VK_SECRET = "vk-service-token-synthetic"
VK_SUBJECT = "100200300"
YANDEX_CLIENT_ID = "yandex-client-synthetic"
YANDEX_SECRET = "yandex-secret-synthetic"
YANDEX_SUBJECT = "4000050006"

VK_SETTINGS: dict[str, Any] = {
    "region": "ru",
    "oauth_vk_client_id": VK_CLIENT_ID,
    "oauth_vk_client_secret": VK_SECRET,
}
YANDEX_SETTINGS: dict[str, Any] = {
    "region": "ru",
    "oauth_yandex_client_id": YANDEX_CLIENT_ID,
    "oauth_yandex_client_secret": YANDEX_SECRET,
}
BOTH_SETTINGS: dict[str, Any] = {**VK_SETTINGS, **YANDEX_SETTINGS, "feature_oauth": True}


@dataclass(frozen=True)
class Call:
    method: str
    url: str
    form: dict[str, str]
    headers: httpx.Headers


def timeout(request: httpx.Request) -> httpx.Response:
    raise httpx.ReadTimeout("timed out", request=request)


class CodeEndpoints:
    """VK ID and Yandex ID as a transport: scripted answers per URL, every call recorded.

    ``replace[url]`` is a response or a function of the request (to play a timeout).
    """

    def __init__(self, *, email: str | None = None) -> None:
        self.calls: list[Call] = []
        self.email = email
        self.replace: dict[str, httpx.Response | Callable[[httpx.Request], httpx.Response]] = {}
        # The accounts behind the codes; ``*_user`` replaces the whole user answer.
        self.vk_subject = VK_SUBJECT
        self.yandex_subject = YANDEX_SUBJECT
        self.vk_user: dict[str, Any] | None = None
        self.yandex_user: dict[str, Any] | None = None

    def transport(self) -> httpx.MockTransport:
        return httpx.MockTransport(self.handler)

    def handler(self, request: httpx.Request) -> httpx.Response:
        url = str(request.url).split("?")[0]
        form = dict(urllib.parse.parse_qsl(request.content.decode()))
        self.calls.append(Call(request.method, str(request.url), form, request.headers))
        scripted = self.replace.get(url)
        if callable(scripted):
            return scripted(request)
        if scripted is not None:
            return scripted
        return self._default(url, form)

    def _default(self, url: str, form: dict[str, str]) -> httpx.Response:
        if url == VK_TOKEN_URL:
            return httpx.Response(
                200,
                json={
                    "access_token": ACCESS_TOKEN,
                    "refresh_token": REFRESH_TOKEN,
                    "id_token": "synthetic.id.token",
                    "user_id": int(self.vk_subject),
                    "state": form.get("state"),
                    "expires_in": 3600,
                },
            )
        if url == VK_USER_INFO_URL:
            user = {"user_id": self.vk_subject} if self.vk_user is None else dict(self.vk_user)
            if self.email is not None:
                user["email"] = self.email
            return httpx.Response(200, json={"user": user})
        if url == YANDEX_TOKEN_URL:
            return httpx.Response(
                200,
                json={
                    "access_token": ACCESS_TOKEN,
                    "refresh_token": REFRESH_TOKEN,
                    "token_type": "bearer",
                },
            )
        if url == YANDEX_INFO_URL:
            user = (
                {"id": self.yandex_subject, "client_id": YANDEX_CLIENT_ID}
                if self.yandex_user is None
                else dict(self.yandex_user)
            )
            if self.email is not None:
                user["default_email"] = self.email
            return httpx.Response(200, json=user)
        return httpx.Response(404)

    def to(self, url: str) -> list[Call]:
        return [call for call in self.calls if call.url.split("?")[0] == url]


def settings_for(**overrides: Any) -> Settings:
    return make_settings(**{**BOTH_SETTINGS, **overrides})
