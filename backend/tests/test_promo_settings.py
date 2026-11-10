"""Settings of promo codes (ADR 0018 sections 3 and 4): the HMAC key and the limits."""

from __future__ import annotations

import base64
import os

import pytest
from pydantic import ValidationError

from tests.conftest import make_settings

JWT_SECRET = "test-secret-test-secret-test-secret-0123"


def key_b64(seed: int = 7) -> str:
    return base64.b64encode(bytes((seed + i) % 256 for i in range(32))).decode()


def test_the_feature_is_off_and_needs_no_key_by_default() -> None:
    settings = make_settings()
    assert settings.feature_promo_codes is False
    assert settings.promo_code_hmac_key is None
    assert settings.promo_key_bytes() is None
    assert settings.promo_code_length == 20
    assert settings.promo_max_failed_per_day == 5
    assert settings.promo_lockout_window_seconds == 86400
    assert settings.promo_breaker_threshold == 200
    assert settings.promo_breaker_window_seconds == 3600
    assert settings.promo_breaker_block_seconds == 900


def test_a_valid_key_is_decoded_to_32_bytes() -> None:
    settings = make_settings(promo_code_hmac_key=key_b64())
    assert settings.promo_key_bytes() == bytes((7 + i) % 256 for i in range(32))


def test_the_key_is_a_secret_in_reprs() -> None:
    settings = make_settings(promo_code_hmac_key=key_b64())
    assert key_b64() not in repr(settings)
    assert key_b64() not in str(settings.model_dump())


@pytest.mark.parametrize(
    "bad",
    [
        base64.b64encode(b"x" * 31).decode(),
        base64.b64encode(b"x" * 33).decode(),
        "not base64 !!!",
        "A" * 43,  # 43 base64 characters decode to 32 bytes only with padding
        key_b64() + "\n junk",
    ],
)
def test_a_key_that_is_not_32_base64_bytes_fails_startup_without_echoing_it(bad: str) -> None:
    with pytest.raises(ValidationError, match="PROMO_CODE_HMAC_KEY") as caught:
        make_settings(promo_code_hmac_key=bad)
    assert bad not in str(caught.value)


def test_the_key_must_differ_from_the_jwt_secret_as_text_and_as_bytes() -> None:
    same_text = base64.b64encode(b"k" * 32).decode()
    with pytest.raises(ValidationError, match="differ from JWT_SECRET") as caught:
        make_settings(promo_code_hmac_key=same_text, jwt_secret=same_text)
    assert same_text not in str(caught.value)
    # A JWT secret that is the key's raw 32 bytes (as text) is the same secret.
    with pytest.raises(ValidationError, match="differ from JWT_SECRET"):
        make_settings(promo_code_hmac_key=base64.b64encode(b"k" * 32).decode(), jwt_secret="k" * 32)


@pytest.mark.parametrize("environment", ["staging", "prod"])
def test_strict_environments_refuse_the_feature_without_a_key(environment: str) -> None:
    with pytest.raises(ValidationError, match="PROMO_CODE_HMAC_KEY is required"):
        make_settings(environment=environment, feature_promo_codes=True)
    ok = make_settings(
        environment=environment, feature_promo_codes=True, promo_code_hmac_key=key_b64()
    )
    assert ok.feature_promo_codes


@pytest.mark.parametrize("environment", ["staging", "prod"])
def test_strict_environments_accept_a_key_with_the_feature_off(environment: str) -> None:
    assert make_settings(environment=environment, promo_code_hmac_key=key_b64())


@pytest.mark.parametrize("environment", ["dev", "test"])
def test_development_may_run_the_feature_without_a_key(environment: str) -> None:
    # Redeeming then answers 503 promo_unavailable; creating codes needs the key.
    assert make_settings(environment=environment, feature_promo_codes=True)


@pytest.mark.parametrize("length", [15, 0, 49])
def test_the_code_length_is_16_to_48(length: int) -> None:
    with pytest.raises(ValidationError):
        make_settings(promo_code_length=length)


@pytest.mark.parametrize("length", [16, 20, 48])
def test_valid_code_lengths(length: int) -> None:
    assert make_settings(promo_code_length=length).promo_code_length == length


@pytest.mark.parametrize(
    "name",
    [
        "promo_max_failed_per_day",
        "promo_lockout_window_seconds",
        "promo_breaker_threshold",
        "promo_breaker_window_seconds",
        "promo_breaker_block_seconds",
        "promo_rate_limit_per_user",
        "promo_rate_limit_per_ip",
        "promo_rate_limit_window_seconds",
    ],
)
def test_limits_must_be_positive(name: str) -> None:
    with pytest.raises(ValidationError):
        make_settings(**{name: 0})


def test_the_environment_variables_are_read(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("FEATURE_PROMO_CODES", "true")
    monkeypatch.setenv("PROMO_CODE_HMAC_KEY", key_b64(3))
    monkeypatch.setenv("PROMO_CODE_LENGTH", "24")
    from app.config import Settings

    monkeypatch.setenv("REGION", "ru")
    monkeypatch.setenv("DATABASE_URL", "postgresql://u:p@localhost/db")
    monkeypatch.setenv("JWT_SECRET", JWT_SECRET)
    settings = Settings()
    assert settings.feature_promo_codes is True
    assert settings.promo_code_length == 24
    assert settings.promo_key_bytes() == bytes((3 + i) % 256 for i in range(32))
    assert os.environ["PROMO_CODE_HMAC_KEY"] not in repr(settings)
