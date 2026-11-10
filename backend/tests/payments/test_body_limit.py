"""The purchase body limit as a bare ASGI middleware (pure: no application behind it)."""

from __future__ import annotations

from types import SimpleNamespace
from typing import Any

import pytest

from app.payments.body_limit import PurchaseBodyLimit


async def run(path: str, body: bytes, *, limit: int = 1024, method: str = "POST") -> list[Any]:
    reached: list[bytes] = []
    sent: list[Any] = []

    async def app(scope: Any, receive: Any, send: Any) -> None:
        message = await receive()
        reached.append(message["body"])
        await send({"type": "http.response.start", "status": 204, "headers": []})
        await send({"type": "http.response.body", "body": b""})

    async def receive() -> Any:
        return {"type": "http.request", "body": body, "more_body": False}

    async def send(message: Any) -> None:
        sent.append(message)

    settings = SimpleNamespace(payments_max_body_bytes=limit)
    scope = {"type": "http", "path": path, "method": method, "headers": []}
    await PurchaseBodyLimit(app, settings)(scope, receive, send)  # type: ignore[arg-type]
    return [m.get("status") for m in sent if m["type"] == "http.response.start"] + reached


@pytest.mark.parametrize(
    "path",
    ["/v1/me/purchases", "/api/v1/me/purchases", "/api/v1/me/purchases/", "/x/y/v1/me/purchases"],
)
async def test_a_prefixed_path_cannot_bypass_the_limit(path: str) -> None:
    assert await run(path, b"x" * 2000) == [413]


async def test_a_body_within_the_limit_reaches_the_application_unchanged() -> None:
    assert await run("/api/v1/me/purchases", b"x" * 100) == [204, b"x" * 100]


@pytest.mark.parametrize("path", ["/v1/me/entitlements", "/v1/auth/login", "/v1/me/purchases/x"])
async def test_other_paths_are_not_limited(path: str) -> None:
    assert (await run(path, b"x" * 2000))[0] == 204


async def test_other_methods_are_not_limited() -> None:
    assert (await run("/v1/me/purchases", b"x" * 2000, method="GET"))[0] == 204
