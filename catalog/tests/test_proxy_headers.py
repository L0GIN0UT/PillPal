"""uvicorn's proxy-header trust, as the image configures it (``FORWARDED_ALLOW_IPS``)."""

from __future__ import annotations

from typing import Any

import pytest
import uvicorn

FORWARDED = [(b"x-forwarded-for", b"198.51.100.7")]


async def _client_seen_by_app(client: tuple[str, int]) -> tuple[str, int] | None:
    seen: list[tuple[str, int] | None] = []

    async def app(scope: dict[str, Any], receive: Any, send: Any) -> None:
        seen.append(scope.get("client"))

    config = uvicorn.Config(app, lifespan="off")
    config.load()
    scope = {"type": "http", "client": client, "headers": FORWARDED}
    await config.loaded_app(scope, None, None)  # type: ignore[arg-type]
    return seen[0]


async def test_an_empty_allow_list_trusts_nobody_not_even_loopback(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("FORWARDED_ALLOW_IPS", "")
    assert await _client_seen_by_app(("127.0.0.1", 1)) == ("127.0.0.1", 1)
    assert await _client_seen_by_app(("10.0.0.5", 1)) == ("10.0.0.5", 1)


async def test_a_listed_proxy_subnet_is_trusted(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("FORWARDED_ALLOW_IPS", "10.0.0.0/8")
    assert (await _client_seen_by_app(("10.0.0.5", 1)))[0] == "198.51.100.7"  # type: ignore[index]
    assert await _client_seen_by_app(("192.0.2.1", 1)) == ("192.0.2.1", 1)
