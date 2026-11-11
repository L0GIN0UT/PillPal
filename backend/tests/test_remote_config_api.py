"""``GET /v1/config`` (milestone 5.12)."""

from __future__ import annotations

import pytest
from httpx import AsyncClient

from app.config import Settings
from app.domain.remote_config import AdsConfig
from tests.helpers import register

ADS = AdsConfig.model_validate(
    {
        "placements": {
            "settings": {"android": "a-settings", "ios": "i-settings"},
            "about": {"ios": "i-about"},
        }
    }
)


@pytest.fixture
def ads_on(monkeypatch: pytest.MonkeyPatch, settings: Settings) -> None:
    monkeypatch.setattr(settings, "remote_config_ads", ADS)


async def test_happy_path_per_platform(client: AsyncClient, ads_on: None) -> None:
    user = await register(client)
    android = await client.get("/v1/config?platform=android", headers=user.headers)
    ios = await client.get("/v1/config?platform=ios", headers=user.headers)
    assert android.status_code == ios.status_code == 200
    assert android.json() == {"ads": {"placements": {"settings": {"unit_id": "a-settings"}}}}
    assert set(ios.json()["ads"]["placements"]) == {"settings", "about"}
    assert android.headers["etag"]
    assert android.headers["etag"] != ios.headers["etag"]
    assert android.headers["cache-control"] == "private, no-cache"


async def test_empty_config(client: AsyncClient) -> None:
    user = await register(client)
    resp = await client.get("/v1/config?platform=android", headers=user.headers)
    assert resp.status_code == 200
    assert resp.json() == {"ads": {"placements": {}}}


async def test_same_body_and_etag_for_every_account(client: AsyncClient, ads_on: None) -> None:
    first = await register(client)
    second = await register(client)
    a = await client.get("/v1/config?platform=ios", headers=first.headers)
    b = await client.get("/v1/config?platform=ios", headers=second.headers)
    assert a.content == b.content
    assert a.headers["etag"] == b.headers["etag"]


async def test_matching_etag_gives_304_without_a_body(client: AsyncClient, ads_on: None) -> None:
    user = await register(client)
    first = await client.get("/v1/config?platform=ios", headers=user.headers)
    etag = first.headers["etag"]
    for value in (etag, f"W/{etag}", f'"other", {etag}', "*"):
        resp = await client.get(
            "/v1/config?platform=ios", headers={**user.headers, "If-None-Match": value}
        )
        assert resp.status_code == 304
        assert resp.content == b""
        assert resp.headers["etag"] == etag


async def test_stale_etag_gives_the_body(client: AsyncClient, ads_on: None) -> None:
    user = await register(client)
    resp = await client.get(
        "/v1/config?platform=ios", headers={**user.headers, "If-None-Match": '"stale"'}
    )
    assert resp.status_code == 200


async def test_etag_changes_with_the_config(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch, settings: Settings
) -> None:
    user = await register(client)
    before = await client.get("/v1/config?platform=ios", headers=user.headers)
    monkeypatch.setattr(settings, "remote_config_ads", ADS)
    after = await client.get(
        "/v1/config?platform=ios", headers={**user.headers, "If-None-Match": before.headers["etag"]}
    )
    assert after.status_code == 200
    assert after.headers["etag"] != before.headers["etag"]


async def test_requires_authentication(client: AsyncClient) -> None:
    resp = await client.get("/v1/config?platform=android")
    assert resp.status_code == 401


@pytest.mark.parametrize("query", ["", "?platform=windows", "?platform=", "?platform=ANDROID"])
async def test_bad_platform_is_422(client: AsyncClient, query: str) -> None:
    user = await register(client)
    resp = await client.get(f"/v1/config{query}", headers=user.headers)
    assert resp.status_code == 422
