"""OAuth settings (ADR 0017 section 1): off by default, matrix refusals, strict partial configs."""

from __future__ import annotations

from pathlib import Path

import pytest
from pydantic import ValidationError

from app.observability import (
    OAUTH_SECRET_KEYS,
    SENSITIVE_KEYS,
    SENTRY_SECRET_KEYS,
    redact_sensitive,
    scrub_sentry_event,
)
from tests.conftest import make_settings

APPLE = {
    "oauth_apple_client_id": "com.example.pillpal",
    "oauth_apple_team_id": "ABCDE12345",
    "oauth_apple_key_id": "KEY1234567",
    "oauth_apple_private_key": "synthetic-key",
}


def test_defaults_are_inert() -> None:
    settings = make_settings()
    assert settings.feature_oauth is False
    assert settings.oauth_fake_provider is False
    assert settings.oauth_nonce_ttl_seconds == 300
    assert settings.oauth_signup_ticket_ttl_seconds == 600
    assert settings.oauth_reauth_max_age_seconds == 300
    assert settings.oauth_http_timeout_seconds == 10


@pytest.mark.parametrize("environment", ["dev", "test", "staging", "prod"])
@pytest.mark.parametrize(
    "extra",
    [
        {"oauth_apple_client_id": "x"},
        {"oauth_google_client_id": "x"},
        {"oauth_apple_private_key": "k"},
    ],
)
def test_ru_refuses_apple_and_google_in_every_environment(
    environment: str, extra: dict[str, str]
) -> None:
    with pytest.raises(ValidationError, match="not allowed when REGION=ru"):
        make_settings(region="ru", environment=environment, **extra)


@pytest.mark.parametrize("environment", ["dev", "test", "staging", "prod"])
@pytest.mark.parametrize(
    "extra",
    [
        {"oauth_vk_client_id": "x"},
        {"oauth_yandex_client_id": "x"},
        {"oauth_vk_client_secret": "s"},
        {"oauth_yandex_client_secret": "s"},
    ],
)
def test_eu_refuses_vk_and_yandex_in_every_environment(
    environment: str, extra: dict[str, str]
) -> None:
    with pytest.raises(ValidationError, match="not allowed when REGION=eu"):
        make_settings(region="eu", environment=environment, **extra)


def test_a_complete_provider_of_the_region_is_accepted() -> None:
    google = make_settings(region="eu", environment="prod", oauth_google_client_id="g")
    assert google.oauth_google_client_id == "g"
    ru = make_settings(
        region="ru",
        environment="prod",
        oauth_vk_client_id="1",
        oauth_vk_client_secret="s",
        oauth_yandex_client_id="2",
        oauth_yandex_client_secret="t",
    )
    assert ru.oauth_vk_client_id == "1"
    assert make_settings(region="eu", environment="prod", **APPLE).oauth_apple_team_id


@pytest.mark.parametrize("environment", ["staging", "prod"])
@pytest.mark.parametrize("missing", list(APPLE))
def test_strict_environments_refuse_a_partial_apple(environment: str, missing: str) -> None:
    partial = {k: v for k, v in APPLE.items() if k != missing}
    with pytest.raises(ValidationError, match="partially configured"):
        make_settings(region="eu", environment=environment, **partial)


@pytest.mark.parametrize("environment", ["staging", "prod"])
@pytest.mark.parametrize(
    "partial",
    [
        {"oauth_vk_client_id": "1"},
        {"oauth_vk_client_secret": "s"},
        {"oauth_yandex_client_id": "1"},
        {"oauth_yandex_client_secret": "s"},
    ],
)
def test_strict_environments_refuse_a_partial_vk_or_yandex(
    environment: str, partial: dict[str, str]
) -> None:
    with pytest.raises(ValidationError, match="partially configured"):
        make_settings(region="ru", environment=environment, **partial)


def test_dev_tolerates_a_partial_provider() -> None:
    assert make_settings(region="eu", environment="dev", oauth_apple_client_id="x")


def test_blank_values_mean_not_configured() -> None:
    settings = make_settings(region="ru", environment="prod", oauth_apple_client_id="  ")
    assert settings.oauth_apple_client_id is None


def test_a_secret_can_come_from_a_file(tmp_path: Path) -> None:
    secret = tmp_path / "vk.secret"
    secret.write_text("file-secret\n", encoding="utf-8")
    settings = make_settings(
        region="ru",
        environment="prod",
        oauth_vk_client_id="1",
        oauth_vk_client_secret_file=str(secret),
    )
    assert settings.oauth_vk_client_secret is not None
    assert settings.oauth_vk_client_secret.get_secret_value() == "file-secret"


def test_a_secret_file_counts_as_configured_for_the_region_rule(tmp_path: Path) -> None:
    secret = tmp_path / "apple.key"
    secret.write_text("k", encoding="utf-8")
    with pytest.raises(ValidationError, match="not allowed when REGION=ru"):
        make_settings(region="ru", oauth_apple_private_key_file=str(secret))


@pytest.mark.parametrize("environment", ["staging", "prod"])
def test_the_fake_provider_is_refused_outside_dev_and_test(environment: str) -> None:
    with pytest.raises(ValidationError, match="OAUTH_FAKE_PROVIDER"):
        make_settings(environment=environment, oauth_fake_provider=True)


@pytest.mark.parametrize("environment", ["dev", "test"])
def test_the_fake_provider_is_allowed_in_dev_and_test(environment: str) -> None:
    assert make_settings(environment=environment, oauth_fake_provider=True).oauth_fake_provider


def test_validation_errors_do_not_echo_secrets() -> None:
    with pytest.raises(ValidationError) as info:
        make_settings(region="ru", oauth_apple_private_key="TOP-SECRET-VALUE")
    assert "TOP-SECRET-VALUE" not in str(info.value)


@pytest.mark.parametrize("key", sorted(OAUTH_SECRET_KEYS))
def test_oauth_secrets_never_reach_logs_or_the_error_tracker(key: str) -> None:
    assert key in SENSITIVE_KEYS
    assert key in SENTRY_SECRET_KEYS
    logged = redact_sensitive(None, "info", {"event": "x", key: "SECRET-VALUE"})
    assert logged[key] == "[redacted]"
    event = {"request": {"data": {key: "SECRET-VALUE"}}, "extra": {"nested": [{key: "SECRET"}]}}
    assert "SECRET" not in str(scrub_sentry_event(event, {}))


@pytest.mark.parametrize(
    "key",
    ["signup_ticket", "assertion", "id_token", "authorization_code", "code_verifier", "nonce"],
)
def test_the_named_bearer_secrets_are_covered(key: str) -> None:
    assert key in OAUTH_SECRET_KEYS


@pytest.mark.parametrize("environment", ["dev", "test", "staging", "prod"])
def test_every_environment_may_enable_the_feature(environment: str) -> None:
    # Passwordless accounts can delete and export since 5.7 (OAuth re-auth): no gate any more.
    assert make_settings(environment=environment, feature_oauth=True).feature_oauth


def test_the_linked_address_is_never_logged() -> None:
    assert "email_at_link" in OAUTH_SECRET_KEYS


def test_a_reauth_form_is_scrubbed_at_depth_in_error_events() -> None:
    form = {"reauth": {"provider": "vk_id", "assertion": "SECRET-TOKEN", "nonce": "SECRET-NONCE"}}
    event = {"request": {"data": {**form, "password": "SECRET-PASSWORD"}}}
    scrubbed = str(scrub_sentry_event(event, {}))
    for secret in ("SECRET-TOKEN", "SECRET-NONCE", "SECRET-PASSWORD"):
        assert secret not in scrubbed
