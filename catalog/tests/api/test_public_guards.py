"""What the public API refuses or withholds: credentials, browsers, floods, oversized bodies and
slow statements; and what it never writes to a log (docs/phase4-plan.md 4.5, ADR 0011 and 0015)."""

from __future__ import annotations

import json
import uuid
from collections.abc import AsyncIterator, Callable
from contextlib import asynccontextmanager

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine
from starlette.types import Message

from catalog.bodylimit import BodyLimitMiddleware
from catalog.domain.gtin import check_digit
from catalog.main import create_app
from tests.api.seed import Seed
from tests.conftest import make_settings

INSTALL_A = "install-aaaaaaaaaaaaaaaa"
INSTALL_B = "install-bbbbbbbbbbbbbbbb"
PUBLIC_REQUESTS: list[tuple[str, str, dict[str, object] | None]] = [
    ("POST", "/v1/search", {"q": "paracetamol", "lang": "en"}),
    ("POST", "/v1/gtins/lookup", {"gtin": "04607012345677"}),
    ("POST", "/v1/products/get", {"id": "00000000-0000-4000-8000-000000000000"}),
    ("GET", "/v1/sources", None),
]


@asynccontextmanager
async def app_client(**overrides: object) -> AsyncIterator[tuple[AsyncClient, FastAPI]]:
    app = create_app(make_settings(**overrides))
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as c:
            yield c, app


@pytest.mark.parametrize(("method", "path", "body"), PUBLIC_REQUESTS)
async def test_authorization_is_refused_not_ignored(
    client: AsyncClient, method: str, path: str, body: dict[str, object] | None
) -> None:
    response = await client.request(
        method, path, json=body, headers={"Authorization": "Bearer backend-token-sentinel"}
    )
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "unexpected_authorization"
    assert "sentinel" not in response.text


@pytest.mark.parametrize(("method", "path", "body"), PUBLIC_REQUESTS)
async def test_no_credentials_are_required(
    client: AsyncClient, method: str, path: str, body: dict[str, object] | None
) -> None:
    response = await client.request(method, path, json=body)
    assert response.status_code in (200, 404)  # 404: the probe id of products/get is unknown


@pytest.mark.parametrize(("method", "path", "body"), PUBLIC_REQUESTS)
async def test_there_is_no_cors(
    client: AsyncClient, method: str, path: str, body: dict[str, object] | None
) -> None:
    origin = {"Origin": "https://example.invalid"}
    simple = await client.request(method, path, json=body, headers=origin)
    preflight = await client.options(
        path, headers={**origin, "Access-Control-Request-Method": method}
    )
    for response in (simple, preflight):
        assert not [h for h in response.headers if h.lower().startswith("access-control-")]
    assert preflight.status_code == 405


async def test_per_install_and_per_ip_limits_answer_429(clean_redis: None) -> None:
    async with app_client(rate_limit_ip_max=5, rate_limit_install_max=2) as (client, _):
        body = {"q": "paracetamol", "lang": "en"}
        for _i in range(2):
            ok = await client.post(
                "/v1/search", json=body, headers={"X-Catalog-Install": INSTALL_A}
            )
            assert ok.status_code == 200
        blocked = await client.post(
            "/v1/search", json=body, headers={"X-Catalog-Install": INSTALL_A}
        )
        assert blocked.status_code == 429
        assert blocked.json()["error"]["code"] == "rate_limited"
        assert int(blocked.headers["retry-after"]) > 0
        # another install still passes until the IP bucket (5 per window) is used up
        other = await client.post("/v1/search", json=body, headers={"X-Catalog-Install": INSTALL_B})
        assert other.status_code == 200
        for _i in range(2):
            await client.get("/v1/sources")
        ip_blocked = await client.get("/v1/sources")
        assert ip_blocked.status_code == 429


@pytest.mark.parametrize(("method", "path", "body"), PUBLIC_REQUESTS)
async def test_rate_limit_applies_to_every_public_route(
    clean_redis: None, method: str, path: str, body: dict[str, object] | None
) -> None:
    async with app_client(rate_limit_ip_max=1) as (client, _):
        assert (await client.request(method, path, json=body)).status_code != 429
        assert (await client.request(method, path, json=body)).status_code == 429


async def test_oversized_bodies_are_413_before_parsing(client: AsyncClient) -> None:
    body = {"q": "x" * 5000, "lang": "en"}
    response = await client.post("/v1/search", json=body)
    assert response.status_code == 413
    assert response.json()["error"]["code"] == "payload_too_large"
    assert "xxxx" not in response.text


async def test_a_chunked_body_without_content_length_is_413_too(client: AsyncClient) -> None:
    async def chunks() -> AsyncIterator[bytes]:
        for _ in range(20):
            yield b'{"q": "' + b"x" * 500

    response = await client.post(
        "/v1/search", content=chunks(), headers={"Content-Type": "application/json"}
    )
    assert response.status_code == 413
    assert response.json()["error"]["code"] == "payload_too_large"


async def test_streamed_bodies_are_cut_off_at_the_cap() -> None:
    reached: list[int] = []

    async def inner(scope: dict[str, object], receive: Callable[[], object], send: object) -> None:
        total = 0
        while True:
            message = await receive()  # type: ignore[misc]
            total += len(message.get("body", b""))  # type: ignore[attr-defined]
            reached.append(total)
            if not message.get("more_body"):  # type: ignore[attr-defined]
                break

    chunks = [b"x" * 600] * 10
    sent: list[Message] = []

    async def receive() -> Message:
        chunk = chunks.pop(0)
        return {"type": "http.request", "body": chunk, "more_body": bool(chunks)}

    async def send(message: Message) -> None:
        sent.append(message)

    middleware = BodyLimitMiddleware(inner, max_bytes=1024)  # type: ignore[arg-type]
    scope = {"type": "http", "method": "POST", "path": "/v1/search", "headers": []}
    await middleware(scope, receive, send)
    assert sent[0]["status"] == 413
    assert max(reached) <= 1200  # stopped near the cap, not after the whole stream


async def test_a_statement_over_the_timeout_is_503_without_sql(
    engine: AsyncEngine, seed: Seed, capsys: pytest.CaptureFixture[str]
) -> None:
    await seed.product("p", "Testamol")
    capsys.readouterr()
    async with app_client(search_statement_timeout_ms=100) as (client, _):
        # An exclusive lock makes the statement wait, which is deterministic where a "slow query"
        # would not be: the timeout counts lock waits too.
        async with engine.connect() as blocker:
            await blocker.execute(
                text("LOCK TABLE catalog.search_entries IN ACCESS EXCLUSIVE MODE")
            )
            response = await client.post(
                "/v1/search", json={"q": "sentinelquerytext", "lang": "en"}
            )
            await blocker.rollback()
        assert response.status_code == 503
        assert response.json() == {
            "error": {"code": "search_timeout", "message": "The catalog is busy, try again"}
        }
        for needle in ("SELECT", "search_entries", "sentinelquerytext", "statement"):
            assert needle not in response.text
        # the pool is healthy afterwards and the timeout did not stick to the connection
        assert (
            await client.post("/v1/search", json={"q": "testamol", "lang": "en"})
        ).status_code == 200
    assert "sentinelquerytext" not in capsys.readouterr().out


def _server_output(out: str) -> str:
    return "\n".join(line for line in out.splitlines() if '"logger": "httpx"' not in line)


async def test_no_query_gtin_product_id_or_address_reaches_the_log(
    seed: Seed, capsys: pytest.CaptureFixture[str], clean_redis: None
) -> None:
    code = "0460701234567"
    gtin = code + check_digit(code)
    pid = await seed.product("p", "Sentineldrug", packages=[("pack", [gtin])])
    missing = str(uuid.uuid4())
    sentinels = ("sentinelquerytext", gtin, gtin[1:], str(pid), missing, "127.0.0.1", INSTALL_A)
    capsys.readouterr()
    async with app_client(rate_limit_install_max=7, rate_limit_ip_max=100) as (client, _):
        headers = {"X-Catalog-Install": INSTALL_A}
        calls = [
            ("/v1/search", {"q": "sentinelquerytext", "lang": "en"}),
            ("/v1/search", {"q": "x", "lang": "en"}),  # 422
            ("/v1/search", {"q": gtin, "lang": "en"}),
            ("/v1/gtins/lookup", {"gtin": gtin}),
            ("/v1/gtins/lookup", {"gtin": gtin[:-1] + "x"}),  # 422
            ("/v1/products/get", {"id": str(pid)}),
            ("/v1/products/get", {"id": missing}),  # 404
            ("/v1/search", {"q": "sentinelquerytext", "lang": "en"}),  # 429
        ]
        statuses = [
            (await client.post(path, json=body, headers=headers)).status_code
            for path, body in calls
        ]
        auth = await client.post(
            "/v1/search",
            json={"q": "sentinelquerytext", "lang": "en"},
            headers={"Authorization": "Bearer sentinelquerytext"},
        )
    assert statuses == [200, 422, 200, 200, 422, 200, 404, 429]
    assert auth.status_code == 400
    out = _server_output(capsys.readouterr().out)
    assert '"event": "http_request"' in out  # the access log did run
    for needle in sentinels:
        assert needle not in out, needle
    for line in out.splitlines():
        if line.startswith("{"):
            assert json.loads(line).get("route") in (None, *(p for p, _ in calls)), line


def test_log_processor_redacts_lookup_keys_even_if_someone_logs_them() -> None:
    from catalog.observability import redact_sensitive

    event = {"event": "x", "q": "a", "gtin": "b", "product_id": "c", "install": "e"}
    cleaned = redact_sensitive(None, "info", dict(event))
    assert {k: v for k, v in cleaned.items() if k != "event"} == dict.fromkeys(
        ("q", "gtin", "product_id", "install"), "[redacted]"
    )
