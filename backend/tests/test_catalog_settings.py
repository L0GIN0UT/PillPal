"""Settings of the catalog integration (milestone 4.6) and ``/v1/me/features``."""

from __future__ import annotations

import pytest
from httpx import AsyncClient
from pydantic import ValidationError

from app.config import Settings
from app.observability import SENTRY_SECRET_KEYS, redact_sensitive, scrub_sentry_event
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
        environment=environment,
        catalog_contributions_enabled=True,
        catalog_internal_url="http://catalog:8001",
        catalog_ingest_token="t" * 40,
    ).catalog_contributions_enabled


@pytest.mark.parametrize("environment", ["staging", "prod"])
def test_strict_environments_accept_the_default(environment: str) -> None:
    assert not make_settings(environment=environment).catalog_contributions_enabled


@pytest.mark.parametrize(
    ("raw", "expected"), [("1,2", [1, 2]), (" 3 , 4 ", [3, 4]), ("[1, 5]", [1, 5]), ("7", [7])]
)
def test_consent_versions_come_from_the_environment_as_csv_or_json(
    monkeypatch: pytest.MonkeyPatch, raw: str, expected: list[int]
) -> None:
    monkeypatch.setenv("GTIN_LINK_CONSENT_VERSIONS", raw)
    settings = Settings.model_validate(
        {
            "region": "ru",
            "database_url": "postgresql://u:p@127.0.0.1/x",
            "jwt_secret": "test-secret-test-secret-test-secret-0123",
        }
    )
    assert settings.gtin_link_consent_versions == expected


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


def test_the_scrubbed_keys_follow_what_tombstones_erase() -> None:
    from app.db.medication_checks import MEDICATION_CONTENT
    from app.db.models import PROFILE_CONTENT, SCHEDULE_CONTENT
    from app.observability import SENSITIVE_KEYS

    erased = {*MEDICATION_CONTENT, *PROFILE_CONTENT, *SCHEDULE_CONTENT}
    personal = {"note", "email", "q", "name", "display_name", "rule", "stock_count", "form"}
    assert erased | personal <= SENSITIVE_KEYS
    assert erased | personal <= SENTRY_SECRET_KEYS
    assert {"password", "refresh_token", "authorization", "restore_ticket"} <= SENSITIVE_KEYS


# --- the contribution job (4.7, ADR 0014 section 3) ----------------------------------------


def test_contribution_defaults_follow_decision_d8() -> None:
    settings = make_settings()
    assert settings.catalog_contribution_interval_seconds == 3600
    assert settings.catalog_contribution_min_account_age_days == 7
    assert settings.catalog_contribution_min_reported_count == 2
    assert settings.catalog_internal_url == ""
    assert settings.catalog_ingest_token is None


def test_a_count_of_one_person_can_never_be_configured_to_leave() -> None:
    with pytest.raises(ValidationError):
        make_settings(catalog_contribution_min_reported_count=1)


@pytest.mark.parametrize(
    "overrides",
    [
        {"catalog_contribution_interval_seconds": 59},
        {"catalog_contribution_min_account_age_days": 0},
        {"catalog_contribution_page_size": 0},
        {"catalog_contribution_page_size": 5001},
    ],
)
def test_contribution_limits_are_validated(overrides: dict[str, int]) -> None:
    with pytest.raises(ValidationError):
        make_settings(**overrides)


def test_enabling_contributions_needs_the_catalog_url_and_the_ingest_token() -> None:
    with pytest.raises(ValidationError, match="CATALOG_INTERNAL_URL"):
        make_settings(catalog_contributions_enabled=True, catalog_ingest_token="t" * 40)
    with pytest.raises(ValidationError, match="CATALOG_INGEST_TOKEN"):
        make_settings(catalog_contributions_enabled=True, catalog_internal_url="http://c:8001")
    ok = make_settings(
        catalog_contributions_enabled=True,
        catalog_internal_url="http://catalog-private:8001/",
        catalog_ingest_token="t" * 40,
    )
    assert ok.catalog_internal_url == "http://catalog-private:8001"  # no trailing slash


def test_the_ingest_token_is_a_secret_and_at_least_32_characters() -> None:
    with pytest.raises(ValidationError):
        make_settings(catalog_ingest_token="short")
    settings = make_settings(catalog_ingest_token="t" * 40)
    assert "t" * 40 not in repr(settings)


@pytest.mark.parametrize("environment", ["staging", "prod"])
def test_strict_environments_require_https_for_the_catalog_url(environment: str) -> None:
    with pytest.raises(ValidationError, match="https"):
        make_settings(environment=environment, catalog_internal_url="http://catalog:8001")
    assert make_settings(
        environment=environment, catalog_internal_url="https://catalog.internal"
    ).catalog_internal_url


@pytest.mark.parametrize("url", ["ftp://x", "catalog:8001", "http://u:p@host", "http://h/?q=1"])
def test_the_catalog_url_is_a_bare_http_origin_without_credentials(url: str) -> None:
    with pytest.raises(ValidationError):
        make_settings(catalog_internal_url=url)


def test_the_complete_page_has_a_longer_timeout_and_retraction_is_opt_in() -> None:
    settings = make_settings()
    assert settings.catalog_complete_page_timeout_seconds == 120
    assert settings.catalog_complete_page_timeout_seconds > settings.catalog_http_timeout_seconds
    assert settings.catalog_contributions_retract is False


def test_rate_limit_retry_defaults_are_bounded() -> None:
    settings = make_settings()
    assert (settings.catalog_rate_limit_retries, settings.catalog_rate_limit_max_sleep_seconds) == (
        5,
        30,
    )
    with pytest.raises(ValidationError):
        make_settings(catalog_rate_limit_max_sleep_seconds=0)
