"""Settings of the data export: the keyring is checked at startup, strictly (ADR 0016 section 9)."""

from __future__ import annotations

import base64
import json

import pytest
from pydantic import ValidationError

from app.config import Settings
from app.services.data_encryption import DataKeyring
from tests.conftest import make_settings

KEY_1 = base64.b64encode(bytes(range(32))).decode()
KEY_2 = base64.b64encode(bytes(range(32, 64))).decode()
STRICT = ["staging", "prod"]


def bare(**overrides: object) -> Settings:
    """Settings without the keyring the shared test settings carry."""
    return make_settings(
        **{"data_encryption_keys": {}, "data_encryption_key_id": None, **overrides}
    )


def keyring(**extra: object) -> dict[str, object]:
    return {"data_encryption_keys": {"1": KEY_1}, "data_encryption_key_id": 1, **extra}


def test_defaults_keep_the_export_off_without_a_keyring() -> None:
    settings = bare()
    assert settings.feature_data_export is False
    assert DataKeyring.from_settings(settings) is None


def test_a_valid_keyring_builds_a_data_keyring() -> None:
    settings = make_settings(
        **keyring(data_encryption_keys={"1": KEY_1, "2": KEY_2}, data_encryption_key_id=2)
    )
    ring = DataKeyring.from_settings(settings)
    assert ring is not None
    assert ring.current_id == 2


def test_the_keyring_comes_from_json_in_the_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DATA_ENCRYPTION_KEYS", json.dumps({"1": KEY_1}))
    monkeypatch.setenv("DATA_ENCRYPTION_KEY_ID", "1")
    monkeypatch.setenv("REGION", "ru")
    monkeypatch.setenv("DATABASE_URL", "postgresql://u:p@localhost/db")
    monkeypatch.setenv("JWT_SECRET", "x" * 40)
    settings = Settings()  # type: ignore[call-arg]
    assert DataKeyring.from_settings(settings) is not None


@pytest.mark.parametrize(
    "keys",
    [
        {"1": base64.b64encode(b"short").decode()},  # not 32 bytes
        {"1": base64.b64encode(bytes(33)).decode()},
        {"1": "not base64 !!"},
        {"1": ""},
        {"0": KEY_1},  # ids are 1..255
        {"256": KEY_1},
        {"1": KEY_1, "2": KEY_1},  # the same key twice
    ],
)
def test_bad_keys_refuse_startup(keys: dict[str, str]) -> None:
    with pytest.raises(ValidationError):
        make_settings(data_encryption_keys=keys, data_encryption_key_id=1)


def test_the_current_key_must_be_in_the_ring_and_named() -> None:
    with pytest.raises(ValidationError, match="DATA_ENCRYPTION_KEY_ID"):
        make_settings(data_encryption_keys={"1": KEY_1}, data_encryption_key_id=2)
    with pytest.raises(ValidationError, match="DATA_ENCRYPTION_KEY_ID"):
        bare(data_encryption_keys={"1": KEY_1})
    with pytest.raises(ValidationError):
        bare(data_encryption_key_id=1)


def test_the_export_flag_needs_a_keyring_everywhere() -> None:
    with pytest.raises(ValidationError, match="DATA_ENCRYPTION_KEYS"):
        bare(feature_data_export=True)
    assert make_settings(feature_data_export=True, **keyring()).feature_data_export is True


@pytest.mark.parametrize("environment", STRICT)
def test_strict_environments_refuse_the_flag_without_a_keyring(environment: str) -> None:
    with pytest.raises(ValidationError, match="DATA_ENCRYPTION_KEYS"):
        bare(environment=environment, feature_data_export=True)


def test_no_key_may_equal_the_jwt_secret() -> None:
    secret = "A" * 43 + "="  # a 44 character secret that is also valid base64 of 32 bytes
    assert len(base64.b64decode(secret)) == 32
    with pytest.raises(ValidationError, match="JWT_SECRET"):
        make_settings(jwt_secret=secret, **keyring(data_encryption_keys={"1": secret}))
    # The raw bytes of a 32 character secret are a key as well.
    raw = "0123456789abcdef0123456789abcdef"
    with pytest.raises(ValidationError, match="JWT_SECRET"):
        make_settings(
            jwt_secret=raw,
            **keyring(data_encryption_keys={"1": base64.b64encode(raw.encode()).decode()}),
        )


def test_limits_have_sane_defaults() -> None:
    settings = make_settings()
    assert settings.export_ttl_hours == 24
    assert settings.export_cooldown_seconds == 3600
    assert settings.export_max_bytes == 64 * 1024 * 1024
    assert settings.export_retention_days == 7
    assert settings.export_build_lease_seconds > 600  # longer than the worker's job timeout


def test_no_data_key_may_equal_the_promo_code_key() -> None:
    with pytest.raises(ValidationError, match="PROMO_CODE_HMAC_KEY"):
        make_settings(promo_code_hmac_key=KEY_2, **keyring(data_encryption_keys={"1": KEY_2}))
    ok = make_settings(promo_code_hmac_key=KEY_2, **keyring())
    assert ok.data_encryption_keys


def test_the_size_cap_is_bounded_and_the_ttl_fits_the_retention() -> None:
    assert make_settings(export_max_bytes=64 * 1024 * 1024).export_max_bytes == 64 * 1024 * 1024
    with pytest.raises(ValidationError):
        make_settings(export_max_bytes=64 * 1024 * 1024 + 1)  # an integer column and memory
    with pytest.raises(ValidationError, match="EXPORT_TTL_HOURS"):
        make_settings(export_ttl_hours=49, export_retention_days=2)
    assert make_settings(export_ttl_hours=48, export_retention_days=2).export_ttl_hours == 48
