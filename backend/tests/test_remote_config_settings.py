"""``REMOTE_CONFIG_ADS`` validation: ads only on the allowlist of ADR 0018 section 2 (5.12)."""

from __future__ import annotations

import pytest
from pydantic import ValidationError

from app.config import Settings
from app.domain.remote_config import ADS_ALLOWED_SCREENS, AdsConfig, placements_for
from tests.conftest import make_settings

FORBIDDEN_SCREENS = [
    "reminder",
    "dose",
    "today",
    "medication",
    "history",
    "relatives",
    "reports",
    "catalog",
    "scan",
    "consent",
    "export",
    "privacy",
    "family",
    "unknown_screen",
    "",
    "Settings",
]


def test_allowlist_is_settings_and_about() -> None:
    assert {"settings", "about"} == ADS_ALLOWED_SCREENS


def test_default_is_empty() -> None:
    assert make_settings().remote_config_ads.placements == {}


@pytest.mark.parametrize("screen", FORBIDDEN_SCREENS)
def test_every_other_screen_is_refused_at_startup(screen: str) -> None:
    with pytest.raises(ValidationError, match="allowlist"):
        make_settings(remote_config_ads={"placements": {screen: {"android": "unit-1"}}})


def test_one_forbidden_screen_among_allowed_ones_is_refused() -> None:
    with pytest.raises(ValidationError, match="allowlist"):
        make_settings(
            remote_config_ads={
                "placements": {"settings": {"android": "a"}, "dose": {"android": "b"}}
            }
        )


@pytest.mark.parametrize(
    ("raw", "reason"),
    [
        ({"unexpected": 1}, "extra_forbidden"),
        ({"placements": {"settings": {"windows": "x"}}}, "extra_forbidden"),
        ({"placements": {"settings": {"android": ""}}}, "string_too_short"),
        ({"placements": {"settings": {"android": "x" * 129}}}, "string_too_long"),
    ],
)
def test_unknown_fields_and_bad_ids_are_refused(raw: dict[str, object], reason: str) -> None:
    with pytest.raises(ValidationError) as excinfo:
        make_settings(remote_config_ads=raw)
    assert reason in {error["type"] for error in excinfo.value.errors()}


def _settings_from_env(monkeypatch: pytest.MonkeyPatch, value: str) -> Settings:
    monkeypatch.setenv("REMOTE_CONFIG_ADS", value)
    return Settings.model_validate(
        {
            "region": "ru",
            "database_url": "postgresql+asyncpg://x/y",
            "jwt_secret": "test-secret-test-secret-test-secret-0123",
        }
    )


def test_json_from_the_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    settings = _settings_from_env(monkeypatch, '{"placements": {"about": {"ios": "unit-9"}}}')
    assert settings.remote_config_ads.placements["about"].ios == "unit-9"


@pytest.mark.parametrize("blank", ["", "   ", "\n\t"])
def test_empty_or_blank_environment_value_means_no_ads(
    monkeypatch: pytest.MonkeyPatch, blank: str
) -> None:
    assert _settings_from_env(monkeypatch, blank).remote_config_ads.placements == {}


def test_malformed_json_stops_startup_without_echoing_it(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    with pytest.raises(ValidationError, match="not valid JSON") as excinfo:
        _settings_from_env(monkeypatch, '{"placements": secret-unit-id')
    assert "secret-unit-id" not in str(excinfo.value)


def test_forbidden_screen_in_the_environment_stops_startup(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    with pytest.raises(ValidationError, match="allowlist"):
        _settings_from_env(monkeypatch, '{"placements": {"dose": {"android": "x"}}}')


def test_placements_for_one_platform_leaves_out_screens_without_an_id() -> None:
    ads = AdsConfig.model_validate(
        {"placements": {"settings": {"android": "a", "ios": "i"}, "about": {"ios": "j"}}}
    )
    assert placements_for(ads, "android") == {"settings": "a"}
    assert placements_for(ads, "ios") == {"settings": "i", "about": "j"}
