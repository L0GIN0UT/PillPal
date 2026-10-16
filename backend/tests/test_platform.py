"""Health checks, error envelope, request-id and logging hygiene."""

from __future__ import annotations

import json
import uuid
from typing import Any

import pytest
from fastapi import APIRouter
from httpx import ASGITransport, AsyncClient

from app.config import Settings
from app.email import InMemoryEmailSender
from app.main import create_app
from tests.conftest import make_settings
from tests.helpers import register


async def test_healthz_is_liveness_only(client: AsyncClient) -> None:
    resp = await client.get("/healthz")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


async def test_readyz_checks_db_and_redis(client: AsyncClient) -> None:
    resp = await client.get("/readyz")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok", "checks": {"database": "ok", "redis": "ok"}}


async def test_readyz_reports_unavailable_redis(migrated_db: str) -> None:
    settings = make_settings(redis_url="redis://127.0.0.1:1/0")
    app = create_app(settings, email_sender=InMemoryEmailSender())
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as c:
            resp = await c.get("/readyz")
    assert resp.status_code == 503
    body = resp.json()
    assert body["error"]["code"] == "not_ready"
    assert "redis" in body["error"]["message"]


async def test_readyz_reports_unavailable_database(migrated_db: str) -> None:
    settings = make_settings(database_url="postgresql+asyncpg://postgres:postgres@127.0.0.1:1/x")
    app = create_app(settings, email_sender=InMemoryEmailSender())
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as c:
            resp = await c.get("/readyz")
    assert resp.status_code == 503
    assert "database" in resp.json()["error"]["message"]


async def test_request_id_is_generated_and_echoed(client: AsyncClient) -> None:
    resp = await client.get("/healthz")
    generated = resp.headers["X-Request-ID"]
    assert len(generated) >= 16

    resp = await client.get("/healthz", headers={"X-Request-ID": "abc-123"})
    assert resp.headers["X-Request-ID"] == "abc-123"


async def test_invalid_request_id_is_replaced(client: AsyncClient) -> None:
    resp = await client.get("/healthz", headers={"X-Request-ID": "bad id\twith junk" * 10})
    assert resp.headers["X-Request-ID"] != "bad id\twith junk" * 10


async def test_unknown_route_uses_error_envelope(client: AsyncClient) -> None:
    resp = await client.get("/v1/nope")
    assert resp.status_code == 404
    assert resp.json() == {"error": {"code": "not_found", "message": "Not found"}}


async def test_method_not_allowed_uses_error_envelope(client: AsyncClient) -> None:
    resp = await client.put("/healthz")
    assert resp.status_code == 405
    assert resp.json()["error"]["code"] == "method_not_allowed"


async def test_validation_error_envelope_does_not_echo_input(client: AsyncClient) -> None:
    resp = await client.post(
        "/v1/auth/register",
        json={"email": "not-an-email", "password": "s3cret-value-here", "region": "ru"},
    )
    assert resp.status_code == 422
    body = resp.json()
    assert body["error"]["code"] == "validation_error"
    assert isinstance(body["error"]["message"], str)
    assert "s3cret-value-here" not in resp.text
    assert all(set(d) == {"loc", "msg"} for d in body["error"]["details"])


async def test_malformed_json_is_validation_error(client: AsyncClient) -> None:
    resp = await client.post(
        "/v1/auth/login", content=b"{not json", headers={"Content-Type": "application/json"}
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "validation_error"


async def test_unhandled_exception_returns_500_envelope_without_trace(
    migrated_db: str, capsys: pytest.CaptureFixture[str]
) -> None:
    settings: Settings = make_settings()
    app = create_app(settings, email_sender=InMemoryEmailSender())
    boom = APIRouter()

    @boom.get("/boom")
    async def _boom() -> None:
        raise RuntimeError("secret internal detail")

    app.include_router(boom)
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as c:
            resp = await c.get("/boom", headers={"X-Request-ID": "req-500"})
    assert resp.status_code == 500
    assert resp.json() == {"error": {"code": "internal_error", "message": "Internal server error"}}
    assert resp.headers["X-Request-ID"] == "req-500"
    assert "secret internal detail" not in resp.text
    logs = _json_lines(capsys.readouterr().out)
    assert any(e.get("event") == "unhandled_exception" for e in logs)


async def test_cors_is_off_by_default(client: AsyncClient) -> None:
    resp = await client.options(
        "/v1/auth/login",
        headers={"Origin": "https://evil.example", "Access-Control-Request-Method": "POST"},
    )
    assert "access-control-allow-origin" not in resp.headers


async def test_cors_can_be_enabled(migrated_db: str) -> None:
    app = create_app(
        make_settings(cors_origins=["https://app.example"]), email_sender=InMemoryEmailSender()
    )
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as c:
            resp = await c.options(
                "/v1/auth/login",
                headers={
                    "Origin": "https://app.example",
                    "Access-Control-Request-Method": "POST",
                },
            )
    assert resp.headers["access-control-allow-origin"] == "https://app.example"


async def test_openapi_is_served(client: AsyncClient) -> None:
    resp = await client.get("/openapi.json")
    assert resp.status_code == 200
    assert "/v1/sync/push" in resp.json()["paths"]


def _json_lines(out: str) -> list[dict[str, Any]]:
    events = []
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("{"):
            events.append(json.loads(line))
    return events


async def test_logs_are_json_with_request_id_and_no_sensitive_data(
    client: AsyncClient, capsys: pytest.CaptureFixture[str]
) -> None:
    capsys.readouterr()
    email = f"Secret.Person-{uuid.uuid4().hex[:6]}@example.com"
    user = await register(client, email=email, password="Pa55word-very-secret")
    med = await client.post(
        f"/v1/profiles/{user.self_profile_id}/medications",
        json={
            "id": str(uuid.uuid4()),
            "name": "Ultrasecretmedname",
            "notes": "confidential-note",
            "tz_mode": "local",
            "privacy": "hidden",
        },
        headers={**user.headers, "X-Request-ID": "req-log-1"},
    )
    assert med.status_code == 201
    await client.post("/v1/auth/login", json={"email": email, "password": "wrong-password-x"})

    out = capsys.readouterr().out
    events = _json_lines(out)
    assert events, "expected JSON log lines"
    access = [e for e in events if e.get("event") == "http_request"]
    assert any(e.get("request_id") == "req-log-1" for e in access)
    for e in access:
        assert {"method", "path", "status", "duration_ms"} <= set(e)
    for needle in (
        "Ultrasecretmedname",
        "confidential-note",
        "Pa55word-very-secret",
        email,
        email.lower(),
        user.access_token,
        user.refresh_token,
    ):
        assert needle not in out
