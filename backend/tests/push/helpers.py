"""Shared pieces of the provider sender tests: throw-away keys and a recording transport."""

from __future__ import annotations

import json
import uuid
from collections.abc import Callable
from datetime import UTC, datetime
from functools import cache
from typing import Any

import httpx
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa

from app.push.base import PushMessage, PushPayload, PushProvider

NOW = datetime(2026, 10, 17, 12, 0, tzinfo=UTC)
ALERT_ID = uuid.UUID("11111111-1111-4111-8111-111111111111")
PROFILE_ID = uuid.UUID("22222222-2222-4222-8222-222222222222")
MEDICATION_ID = uuid.UUID("33333333-3333-4333-8333-333333333333")
FCM_TOKEN = "fcm-token-AAAA_bbbb:CCCC-dddd"
APNS_TOKEN = "ab" * 32
RUSTORE_TOKEN = "rustore-token-1234"


class Clock:
    def __init__(self, now: datetime = NOW) -> None:
        self.now = now

    def __call__(self) -> datetime:
        return self.now


@cache
def rsa_private_pem() -> str:
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    return key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()


@cache
def ec_private_pem() -> str:
    key = ec.generate_private_key(ec.SECP256R1())
    return key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    ).decode()


def public_pem(private_pem: str) -> str:
    key = serialization.load_pem_private_key(private_pem.encode(), password=None)
    return (
        key.public_key()
        .public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)
        .decode()
    )


def service_account_json(token_uri: str = "https://evil.example/token") -> str:  # noqa: S107
    return json.dumps(
        {
            "type": "service_account",
            "client_email": "svc@example-project.iam.gserviceaccount.com",
            "private_key": rsa_private_pem(),
            "private_key_id": "kid-1",
            "token_uri": token_uri,
        }
    )


def message(
    provider: PushProvider,
    token: str,
    *,
    kind: str = "missed",
    with_medication: bool = True,
    environment: str | None = None,
) -> PushMessage:
    if kind == "missed":
        payload = PushPayload(
            t="missed",
            a=ALERT_ID,
            p=PROFILE_ID,
            m=MEDICATION_ID if with_medication else None,
            s="u",
        )
    else:
        payload = PushPayload(t="link_accepted", p=PROFILE_ID, g=ALERT_ID)
    return PushMessage(
        provider=provider,
        token=token,
        payload=payload,
        delivery_id="42",
        apns_environment=environment,  # type: ignore[arg-type]
        ttl_seconds=7200,
    )


class Recorder:
    """An ``httpx.MockTransport`` handler that records requests and answers from a function."""

    def __init__(self, respond: Callable[[httpx.Request], httpx.Response]) -> None:
        self.respond = respond
        self.requests: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        return self.respond(request)

    def client(self, *, http2: bool = False) -> httpx.AsyncClient:
        return httpx.AsyncClient(transport=httpx.MockTransport(self), http2=http2)

    def json_body(self, index: int = -1) -> Any:
        return json.loads(self.requests[index].content)
