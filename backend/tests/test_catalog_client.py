"""The catalog ingest client and the snapshot push (ADR 0014 section 3), over a fake transport."""

from __future__ import annotations

import json
import uuid
from datetime import UTC, datetime
from typing import Any

import httpx
import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.catalog_client import CatalogIngestClient, CatalogUploadError
from app.config import Settings
from app.services.catalog_contributions import Confirmation, push_gtin_confirmations
from tests.catalog_helpers import GTIN, OTHER_GTIN, PRODUCT, contributor
from tests.conftest import make_settings

pytestmark = pytest.mark.usefixtures("contributions_on")

TOKEN = "ingest-token-" + "x" * 32
NOW = datetime(2026, 11, 10, 12, 0, tzinfo=UTC)
NOW_MS = int(NOW.timestamp() * 1000)


def enabled(**overrides: Any) -> Settings:
    values: dict[str, Any] = {
        "catalog_contributions_enabled": True,
        "catalog_internal_url": "http://catalog-private:8001",
        "catalog_ingest_token": TOKEN,
    }
    values.update(overrides)
    return make_settings(**values)


class Recorder:
    """A fake catalog: records requests and answers with the queued statuses."""

    def __init__(self, *statuses: int) -> None:
        self.requests: list[httpx.Request] = []
        self._statuses = list(statuses)

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        status = self._statuses.pop(0) if self._statuses else 200
        return httpx.Response(status, json={"status": "committed", "dropped": 0})

    def bodies(self) -> list[dict[str, Any]]:
        return [json.loads(r.content) for r in self.requests]


def client_for(settings: Settings, recorder: Recorder) -> CatalogIngestClient:
    return CatalogIngestClient(settings, transport=httpx.MockTransport(recorder))


async def put_one(client: CatalogIngestClient, *, complete: bool = True) -> None:
    await client.put_page(
        generation=7, page=0, complete=complete, items=[Confirmation(GTIN, PRODUCT, 3)]
    )


async def test_a_page_is_one_put_with_the_region_token_and_nothing_else() -> None:
    recorder = Recorder()
    client = client_for(enabled(), recorder)
    await put_one(client)
    await client.aclose()
    (request,) = recorder.requests
    assert request.method == "PUT"
    assert (
        str(request.url) == "http://catalog-private:8001/internal/v1/regions/ru/gtin-confirmations"
    )
    assert request.headers["authorization"] == f"Bearer {TOKEN}"
    assert "cookie" not in request.headers
    assert "x-device-id" not in request.headers
    (body,) = recorder.bodies()
    assert body == {
        "generation": 7,
        "page": 0,
        "complete": True,
        "items": [{"gtin": GTIN, "product_id": str(PRODUCT), "count": 3}],
    }


async def test_the_region_in_the_path_is_this_backends_region() -> None:
    recorder = Recorder()
    client = client_for(enabled(region="eu"), recorder)
    await put_one(client)
    await client.aclose()
    assert recorder.requests[0].url.path == "/internal/v1/regions/eu/gtin-confirmations"


@pytest.mark.parametrize("status", [401, 403, 409, 413, 429, 500])
async def test_a_refused_page_raises_with_the_status_only(status: int) -> None:
    client = client_for(enabled(), Recorder(status))
    with pytest.raises(CatalogUploadError) as raised:
        await put_one(client)
    await client.aclose()
    assert raised.value.status_code == status
    assert TOKEN not in str(raised.value)
    assert GTIN not in str(raised.value)


async def test_a_transport_failure_raises_without_the_url_or_the_token() -> None:
    def boom(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("could not reach http://catalog-private:8001", request=request)

    client = CatalogIngestClient(enabled(), transport=httpx.MockTransport(boom))
    with pytest.raises(CatalogUploadError) as raised:
        await put_one(client)
    await client.aclose()
    assert raised.value.status_code is None
    assert "catalog-private" not in str(raised.value)
    assert raised.value.__cause__ is None


async def test_a_redirect_is_not_followed_so_the_token_stays_on_the_configured_host() -> None:
    seen: list[httpx.Request] = []

    def redirect(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        return httpx.Response(307, headers={"location": "http://elsewhere.invalid/x"})

    client = CatalogIngestClient(enabled(), transport=httpx.MockTransport(redirect))
    with pytest.raises(CatalogUploadError):
        await put_one(client)
    await client.aclose()
    assert len(seen) == 1


def test_the_client_refuses_to_exist_without_url_and_token() -> None:
    with pytest.raises(ValueError, match="not configured"):
        CatalogIngestClient(make_settings())


# --- the snapshot ----------------------------------------------------------------------------


async def test_a_snapshot_is_paged_with_one_generation_and_complete_on_the_last_page(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
) -> None:
    for gtin in (GTIN, OTHER_GTIN):
        await contributor(client, engine, gtin=gtin)
        await contributor(client, engine, gtin=gtin)
    settings = enabled(catalog_contribution_page_size=1)
    recorder = Recorder()
    ingest = client_for(settings, recorder)
    sent = await push_gtin_confirmations(maker, settings, ingest, datetime.now(UTC))
    await ingest.aclose()
    assert sent == 2
    first, second = recorder.bodies()
    assert (first["page"], first["complete"]) == (0, False)
    assert (second["page"], second["complete"]) == (1, True)
    assert first["generation"] == second["generation"]
    assert [i["gtin"] for i in first["items"] + second["items"]] == [GTIN, OTHER_GTIN]
    for body in (first, second):
        assert set(body) == {"generation", "page", "complete", "items"}
        for item in body["items"]:
            assert set(item) == {"gtin", "product_id", "count"}


async def test_an_empty_snapshot_is_still_sent_so_counts_can_fall_to_zero(
    maker: async_sessionmaker[AsyncSession],
) -> None:
    settings = enabled()
    recorder = Recorder()
    ingest = client_for(settings, recorder)
    assert await push_gtin_confirmations(maker, settings, ingest, NOW) == 0
    await ingest.aclose()
    (body,) = recorder.bodies()
    assert (body["page"], body["complete"], body["items"]) == (0, True, [])
    assert body["generation"] == int(NOW.timestamp() * 1000)


async def test_a_failed_page_stops_the_snapshot(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
) -> None:
    for gtin in (GTIN, OTHER_GTIN):
        await contributor(client, engine, gtin=gtin)
        await contributor(client, engine, gtin=gtin)
    settings = enabled(catalog_contribution_page_size=1)
    recorder = Recorder(500)
    ingest = client_for(settings, recorder)
    with pytest.raises(CatalogUploadError):
        await push_gtin_confirmations(maker, settings, ingest, datetime.now(UTC))
    await ingest.aclose()
    assert len(recorder.requests) == 1  # nothing was marked complete


async def test_a_new_run_uses_a_newer_generation(maker: async_sessionmaker[AsyncSession]) -> None:
    settings = enabled()
    recorder = Recorder()
    ingest = client_for(settings, recorder)
    await push_gtin_confirmations(maker, settings, ingest, NOW)
    await push_gtin_confirmations(maker, settings, ingest, NOW.replace(hour=13))
    await ingest.aclose()
    first, second = recorder.bodies()
    assert second["generation"] > first["generation"]


def test_the_payload_dataclass_has_no_other_identifiers() -> None:
    fields = set(Confirmation.__dataclass_fields__)
    assert fields == {"gtin", "product_id", "count"}
    assert isinstance(Confirmation(GTIN, uuid.uuid4(), 2).product_id, uuid.UUID)


# --- review fixes: timeouts, stale generations, retraction ------------------------------------


class Sequence_:
    """Answers with queued (status, json) pairs, then 200."""

    def __init__(self, *answers: tuple[int, dict[str, Any]]) -> None:
        self.requests: list[httpx.Request] = []
        self._answers = list(answers)

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        status, body = self._answers.pop(0) if self._answers else (200, {"status": "committed"})
        return httpx.Response(status, json=body)

    def bodies(self) -> list[dict[str, Any]]:
        return [json.loads(r.content) for r in self.requests]


def stale(committed: int, minimum: int) -> tuple[int, dict[str, Any]]:
    error = {"code": "generation_stale", "message": "x", "committed_generation": committed}
    return 409, {"error": {**error, "min_generation": minimum}}


async def test_the_complete_page_gets_its_own_longer_timeout() -> None:
    seen: list[dict[str, Any]] = []

    def record(request: httpx.Request) -> httpx.Response:
        seen.append(dict(request.extensions["timeout"]))
        return httpx.Response(200, json={})

    settings = enabled(catalog_http_timeout_seconds=5, catalog_complete_page_timeout_seconds=90)
    client = CatalogIngestClient(settings, transport=httpx.MockTransport(record))
    await put_one(client, complete=False)
    await put_one(client, complete=True)
    await client.aclose()
    assert seen[0]["read"] == 5
    assert seen[1]["read"] == 90


async def test_a_stale_generation_is_retried_once_above_the_hint(
    maker: async_sessionmaker[AsyncSession], caplog: pytest.LogCaptureFixture
) -> None:
    settings = enabled()
    recorder = Sequence_(stale(committed=NOW_MS + 5_000, minimum=NOW_MS + 5_001))
    ingest = CatalogIngestClient(settings, transport=httpx.MockTransport(recorder))
    await push_gtin_confirmations(maker, settings, ingest, NOW)
    await ingest.aclose()
    first, second = recorder.bodies()
    assert first["generation"] == NOW_MS
    assert second["generation"] == NOW_MS + 5_001


async def test_the_retry_never_goes_below_the_clock(
    maker: async_sessionmaker[AsyncSession],
) -> None:
    settings = enabled()
    recorder = Sequence_(stale(committed=3, minimum=4))
    ingest = CatalogIngestClient(settings, transport=httpx.MockTransport(recorder))
    await push_gtin_confirmations(maker, settings, ingest, NOW)
    await ingest.aclose()
    assert recorder.bodies()[1]["generation"] == NOW_MS


async def test_a_second_stale_answer_is_an_error(
    maker: async_sessionmaker[AsyncSession],
) -> None:
    settings = enabled()
    recorder = Sequence_(stale(1, 2), stale(1, 2))
    ingest = CatalogIngestClient(settings, transport=httpx.MockTransport(recorder))
    with pytest.raises(CatalogUploadError) as raised:
        await push_gtin_confirmations(maker, settings, ingest, NOW)
    await ingest.aclose()
    assert (raised.value.status_code, raised.value.code) == (409, "generation_stale")
    assert len(recorder.requests) == 2


async def test_other_conflicts_are_not_retried(maker: async_sessionmaker[AsyncSession]) -> None:
    settings = enabled()
    recorder = Sequence_((409, {"error": {"code": "snapshot_incomplete", "message": "x"}}))
    ingest = CatalogIngestClient(settings, transport=httpx.MockTransport(recorder))
    with pytest.raises(CatalogUploadError):
        await push_gtin_confirmations(maker, settings, ingest, NOW)
    await ingest.aclose()
    assert len(recorder.requests) == 1


async def test_a_stale_retry_is_logged_as_its_own_event(
    maker: async_sessionmaker[AsyncSession], capfd: pytest.CaptureFixture[str]
) -> None:
    settings = enabled()
    ingest = CatalogIngestClient(settings, transport=httpx.MockTransport(Sequence_(stale(1, 2))))
    await push_gtin_confirmations(maker, settings, ingest, NOW)
    await ingest.aclose()
    out = capfd.readouterr()
    assert "catalog_generation_stale" in out.out + out.err


async def test_a_retraction_sends_an_empty_complete_snapshot_even_with_links_present(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
) -> None:
    for _ in range(2):
        await contributor(client, engine)
    settings = enabled()
    recorder = Recorder()
    ingest = client_for(settings, recorder)
    sent = await push_gtin_confirmations(maker, settings, ingest, NOW, retract=True)
    await ingest.aclose()
    assert sent == 0
    (body,) = recorder.bodies()
    assert (body["complete"], body["items"]) == (True, [])
