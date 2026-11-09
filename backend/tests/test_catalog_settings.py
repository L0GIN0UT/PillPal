"""Settings of the catalog integration (milestone 4.6) and ``/v1/me/features``."""

from __future__ import annotations

import pytest
from httpx import AsyncClient
from pydantic import ValidationError

from app.config import Settings
from app.observability import redact_sensitive, scrub_sentry_event
from tests.conftest import make_settings
from tests.helpers import register


def test_contributions_are_off_by_default_and_version_one_is_supported() -> None:
    settings = make_settings()
    assert settings.catalog_contributions_enabled is False
    assert settings.gtin_link_consent_versions == [1]


@pytest.mark.parametrize("environment", ["staging", "prod"])
def test_strict_environments_refuse_contributions_before_consent_records_exist(
    environment: str,
) -> None:
    with pytest.raises(ValidationError, match="CATALOG_CONTRIBUTIONS_ENABLED"):
        make_settings(environment=environment, catalog_contributions_enabled=True)


@pytest.mark.parametrize("environment", ["dev", "test"])
def test_other_environments_may_enable_contributions(environment: str) -> None:
    assert make_settings(
        environment=environment, catalog_contributions_enabled=True
    ).catalog_contributions_enabled


@pytest.mark.parametrize("environment", ["staging", "prod"])
def test_strict_environments_accept_the_default(environment: str) -> None:
    assert not make_settings(environment=environment).catalog_contributions_enabled


def test_consent_versions_must_be_positive_and_not_empty() -> None:
    for bad in ([], [0], [-1]):
        with pytest.raises(ValidationError):
            make_settings(gtin_link_consent_versions=bad)


async def test_features_report_contributions_off_by_default(client: AsyncClient) -> None:
    user = await register(client)
    resp = await client.get("/v1/me/features", headers=user.headers)
    assert resp.json()["catalog_contributions_enabled"] is False


async def test_features_follow_the_setting(
    client: AsyncClient, settings: Settings, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(settings, "catalog_contributions_enabled", True)
    user = await register(client)
    resp = await client.get("/v1/me/features", headers=user.headers)
    assert resp.json()["catalog_contributions_enabled"] is True


@pytest.mark.parametrize(
    "key",
    [
        "gtin",
        "catalog_product_id",
        "catalog_package_id",
        "catalog_composition_id",
        "manual_ingredients",
        "q",
    ],
)
def test_catalog_keys_never_reach_logs_or_the_error_tracker(key: str) -> None:
    logged = redact_sensitive(None, "info", {"event": "x", key: "SECRET-VALUE"})
    assert logged[key] == "[redacted]"
    event = {"request": {"data": {key: "SECRET-VALUE"}}, "extra": {"nested": [{key: "SECRET"}]}}
    assert "SECRET" not in str(scrub_sentry_event(event, {}))
