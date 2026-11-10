"""Helpers of the Apple and Google verifier suites: keys generated here, a JWKS served by
``httpx.MockTransport``, signed ID tokens. Nothing real: every key and token is synthetic."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import urllib.parse
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from typing import Any

import httpx
import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from jwt.algorithms import ECAlgorithm, RSAAlgorithm

from app.config import Settings
from app.oauth.apple_tokens import APPLE_REVOKE_URL, APPLE_TOKEN_URL, AppleTokenClient
from app.oauth.fake import nonce_digest
from tests.conftest import make_settings

NOW = datetime(2026, 11, 10, 12, 0, tzinfo=UTC)
NONCE = "server-nonce-" + "n" * 30
APPLE_CLIENT_ID = "com.example.pillpal"
GOOGLE_ANDROID_ID = "android-client.apps.example"
GOOGLE_IOS_ID = "ios-client.apps.example"
APPLE_ISSUER = "https://appleid.apple.com"
GOOGLE_ISSUER = "https://accounts.google.com"
APPLE_TEAM_ID = "ABCDE12345"
APPLE_KEY_ID = "KEY1234567"

RSA_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
OTHER_RSA_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
EC_KEY = ec.generate_private_key(ec.SECP256R1())
# The Apple "Sign in with Apple" key the server signs its client secret with (PKCS#8 PEM).
APPLE_PRIVATE_KEY_PEM = (
    ec.generate_private_key(ec.SECP256R1())
    .private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    .decode()
)


def public_jwk(key: rsa.RSAPrivateKey | ec.EllipticCurvePrivateKey, kid: str) -> dict[str, Any]:
    public = key.public_key()
    if isinstance(public, rsa.RSAPublicKey):
        jwk = json.loads(RSAAlgorithm.to_jwk(public))
        jwk["alg"] = "RS256"
    else:
        jwk = json.loads(ECAlgorithm.to_jwk(public))
        jwk["alg"] = "ES256"
    return {**jwk, "kid": kid, "use": "sig"}


def claims(
    *, issuer: str, audience: str, nonce: str | None = NONCE, now: datetime = NOW, **extra: Any
) -> dict[str, Any]:
    body: dict[str, Any] = {
        "iss": issuer,
        "aud": audience,
        "sub": "provider-subject-1",
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(hours=1)).timestamp()),
        "email": "Person@Example.com",
        "email_verified": True,
    }
    if nonce is not None:
        body["nonce"] = nonce_digest(nonce)
    body.update(extra)
    return {k: v for k, v in body.items() if v is not None}


def sign(
    body: dict[str, Any],
    *,
    key: Any = RSA_KEY,
    kid: str | None = "k1",
    alg: str = "RS256",
) -> str:
    headers = {"kid": kid} if kid is not None else {}
    return jwt.encode(body, key, algorithm=alg, headers=headers)


def unsigned(body: dict[str, Any]) -> str:
    """An ``alg=none`` token: the signature part is empty."""
    return jwt.encode(body, key=None, algorithm="none", headers={"kid": "k1"})


def hs256_with_public_key(body: dict[str, Any]) -> str:
    """The classic confusion attack: HS256 keyed with the public key bytes."""
    pem = RSA_KEY.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
    )
    return _hs256(body, pem)


def _hs256(body: dict[str, Any], secret: bytes) -> str:
    def b64(raw: bytes) -> str:
        return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()

    head = b64(json.dumps({"alg": "HS256", "typ": "JWT", "kid": "k1"}).encode())
    payload = b64(json.dumps(body).encode())
    mac = hmac.new(secret, f"{head}.{payload}".encode(), hashlib.sha256).digest()
    return f"{head}.{payload}.{b64(mac)}"


class JwksServer:
    """Serves a JWKS and counts the fetches; ``fail`` plays an outage or a timeout."""

    def __init__(self, keys: dict[str, Any] | None = None) -> None:
        self.keys: dict[str, Any] = {"k1": RSA_KEY} if keys is None else keys
        self.requests = 0
        self.fail: Callable[[httpx.Request], httpx.Response] | None = None

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests += 1
        if self.fail is not None:
            return self.fail(request)
        return httpx.Response(
            200, json={"keys": [public_jwk(key, kid) for kid, key in self.keys.items()]}
        )


def timeout(request: httpx.Request) -> httpx.Response:
    raise httpx.ReadTimeout("timed out", request=request)


REFRESH_TOKEN = "r.synthetic-refresh-token-value"
CODE = "c.synthetic-authorization-code"
APPLE_SETTINGS: dict[str, Any] = {
    "region": "eu",
    "oauth_apple_client_id": APPLE_CLIENT_ID,
    "oauth_apple_team_id": APPLE_TEAM_ID,
    "oauth_apple_key_id": APPLE_KEY_ID,
    "oauth_apple_private_key": APPLE_PRIVATE_KEY_PEM,
}


class AppleEndpoints:
    """A MockTransport playing Apple's token and revoke endpoints."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, str]]] = []
        self.token_response: httpx.Response | None = None
        self.revoke_responses: list[httpx.Response] = []

    def id_token(self, subject: str = "provider-subject-1") -> str:
        return sign({"iss": APPLE_ISSUER, "sub": subject, "aud": APPLE_CLIENT_ID})

    def handler(self, request: httpx.Request) -> httpx.Response:
        form = dict(urllib.parse.parse_qsl(request.content.decode()))
        self.calls.append((str(request.url), form))
        if str(request.url) == APPLE_TOKEN_URL:
            return self.token_response or httpx.Response(
                200, json={"refresh_token": REFRESH_TOKEN, "id_token": self.id_token()}
            )
        if str(request.url) == APPLE_REVOKE_URL:
            return self.revoke_responses.pop(0) if self.revoke_responses else httpx.Response(200)
        return httpx.Response(404)

    def client(self, settings: Settings | None = None) -> AppleTokenClient:
        http = httpx.AsyncClient(transport=httpx.MockTransport(self.handler))
        client = AppleTokenClient.from_settings(settings or make_settings(**APPLE_SETTINGS), http)
        assert client is not None
        return client
