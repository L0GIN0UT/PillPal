"""The access log carries method, route template, status and latency; nothing that identifies a
person or what they looked up (docs: catalog traffic is unlinkable to accounts)."""

from __future__ import annotations

import json
from typing import Any

import pytest
from httpx import AsyncClient

EXPECTED_KEYS = {
    "event",
    "level",
    "timestamp",
    "request_id",
    "method",
    "route",
    "status",
    "duration_ms",
}
SENTINELS = (
    "paracetamol",
    "install-sentinel-0123456789",
    "agent-sentinel",
    "bearer-sentinel",
    "cookie-sentinel",
    "body-sentinel",
    "127.0.0.1",
)


def _server_output(out: str) -> str:
    # The test client logs request URLs itself (logger "httpx"); that is not the service's log.
    return "\n".join(line for line in out.splitlines() if '"logger": "httpx"' not in line)


def _access_records(out: str) -> list[dict[str, Any]]:
    records = [json.loads(line) for line in out.splitlines() if line.startswith("{")]
    return [r for r in records if r.get("event") == "http_request"]


async def test_access_log_has_only_route_status_and_latency(
    client: AsyncClient, capsys: pytest.CaptureFixture[str]
) -> None:
    capsys.readouterr()
    response = await client.get(
        "/healthz?q=paracetamol",
        headers={
            "X-Catalog-Install": "install-sentinel-0123456789",
            "User-Agent": "agent-sentinel",
            "Authorization": "Bearer bearer-sentinel",
            "Cookie": "c=cookie-sentinel",
        },
    )
    out = _server_output(capsys.readouterr().out)
    assert response.status_code == 200
    (record,) = _access_records(out)
    assert set(record) == EXPECTED_KEYS
    assert record["route"] == "/healthz"
    assert record["method"] == "GET"
    assert record["status"] == 200
    assert record["duration_ms"] >= 0
    for sentinel in SENTINELS:
        assert sentinel not in out


async def test_unmatched_path_is_logged_as_a_placeholder_not_the_raw_path(
    client: AsyncClient, capsys: pytest.CaptureFixture[str]
) -> None:
    capsys.readouterr()
    response = await client.post("/v1/products/paracetamol-500", content="body-sentinel")
    out = _server_output(capsys.readouterr().out)
    assert response.status_code == 404
    (record,) = _access_records(out)
    assert record["route"] == "<unmatched>"
    assert record["status"] == 404
    for sentinel in SENTINELS:
        assert sentinel not in out
    assert "paracetamol-500" not in out


async def test_incoming_request_id_is_ignored(client: AsyncClient) -> None:
    # A client-chosen id would be a tracking handle across requests.
    response = await client.get("/healthz", headers={"X-Request-ID": "chosen-by-client"})
    assert response.headers["x-request-id"] != "chosen-by-client"
