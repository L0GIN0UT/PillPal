from __future__ import annotations

import hashlib

import pytest
from pydantic import ValidationError

from catalog.config import Settings, normalize_database_url

DB = "postgresql+asyncpg://u:p@localhost:5432/db"


def digest(secret: str) -> str:
    return hashlib.sha256(secret.encode()).hexdigest()


@pytest.fixture(autouse=True)
def _clean_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in (
        "CATALOG_DATABASE_URL",
        "CATALOG_REDIS_URL",
        "ENVIRONMENT",
        "CATALOG_ADMIN_TOKENS",
        "CATALOG_INGEST_TOKENS",
        "CATALOG_RATE_LIMIT_SALT",
    ):
        monkeypatch.delenv(name, raising=False)


def test_database_url_is_required() -> None:
    with pytest.raises(ValidationError, match="CATALOG_DATABASE_URL"):
        Settings()


def test_reads_the_documented_environment_variables(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CATALOG_DATABASE_URL", "postgres://u:p@h/db")
    monkeypatch.setenv("CATALOG_REDIS_URL", "redis://h:6379/5")
    monkeypatch.setenv("ENVIRONMENT", "staging")
    admin = f"ops:{digest('a' * 40)}"
    ingest = f"importer:{digest('b' * 40)}, second:{digest('c' * 40)}"
    monkeypatch.setenv("CATALOG_ADMIN_TOKENS", admin)
    monkeypatch.setenv("CATALOG_INGEST_TOKENS", ingest)
    settings = Settings()
    assert settings.database_url == "postgresql+asyncpg://u:p@h/db"
    assert settings.redis_url == "redis://h:6379/5"
    assert settings.environment == "staging"
    assert [(t.name, t.sha256) for t in settings.admin_tokens] == [("ops", digest("a" * 40))]
    assert [t.name for t in settings.ingest_tokens] == ["importer", "second"]


def test_dev_allows_no_tokens() -> None:
    settings = Settings.model_validate({"database_url": DB})
    assert settings.environment == "dev"
    assert settings.admin_tokens == ()
    assert settings.ingest_tokens == ()


@pytest.mark.parametrize("environment", ["staging", "prod"])
def test_strict_environments_require_both_token_lists(environment: str) -> None:
    good = f"ops:{digest('a' * 40)}"
    other = f"importer:{digest('b' * 40)}"
    base = {"database_url": DB, "environment": environment}
    with pytest.raises(ValidationError, match="CATALOG_ADMIN_TOKENS"):
        Settings.model_validate({**base, "ingest_tokens": other})
    with pytest.raises(ValidationError, match="CATALOG_INGEST_TOKENS"):
        Settings.model_validate({**base, "admin_tokens": good})
    Settings.model_validate({**base, "admin_tokens": good, "ingest_tokens": other})


@pytest.mark.parametrize(
    "raw",
    [
        "ops",  # no digest
        "ops:short",  # not a sha256
        f"ops:{'z' * 64}",  # not hex
        f":{'a' * 64}",  # no name
        f"Bad Name:{'a' * 64}",  # name charset
        f"ops:{'a' * 64},ops:{'b' * 64}",  # duplicate name
    ],
)
def test_malformed_token_entries_are_refused_everywhere(raw: str) -> None:
    with pytest.raises(ValidationError):
        Settings.model_validate({"database_url": DB, "admin_tokens": raw})


def test_a_raw_secret_is_not_accepted_in_place_of_its_digest() -> None:
    # A common mistake: pasting the secret itself. It is neither 64 hex characters nor safe to keep.
    with pytest.raises(ValidationError) as excinfo:
        Settings.model_validate({"database_url": DB, "admin_tokens": f"ops:{'s3cret-' * 6}"})
    assert "s3cret" not in str(excinfo.value)


def test_the_same_token_cannot_be_both_admin_and_ingest() -> None:
    entry = f"x:{digest('a' * 40)}"
    with pytest.raises(ValidationError, match="both"):
        Settings.model_validate({"database_url": DB, "admin_tokens": entry, "ingest_tokens": entry})


def test_unknown_environment_is_refused() -> None:
    with pytest.raises(ValidationError):
        Settings.model_validate({"database_url": DB, "environment": "production"})


@pytest.mark.parametrize(
    ("url", "expected"),
    [
        ("postgres://a@h/d", "postgresql+asyncpg://a@h/d"),
        ("postgresql://a@h/d", "postgresql+asyncpg://a@h/d"),
        ("postgresql+asyncpg://a@h/d", "postgresql+asyncpg://a@h/d"),
        ("sqlite://x", "sqlite://x"),
    ],
)
def test_normalize_database_url(url: str, expected: str) -> None:
    assert normalize_database_url(url) == expected


def test_rate_limit_salt_defaults_to_a_random_value_per_settings_instance() -> None:
    a = Settings.model_validate({"database_url": DB})
    b = Settings.model_validate({"database_url": DB})
    assert len(a.rate_limit_salt.get_secret_value()) >= 32
    assert a.rate_limit_salt.get_secret_value() != b.rate_limit_salt.get_secret_value()
