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
    ingest = f"ru:{digest('b' * 40)}, ru-next:{digest('c' * 40)}"
    monkeypatch.setenv("CATALOG_ADMIN_TOKENS", admin)
    monkeypatch.setenv("CATALOG_INGEST_TOKENS", ingest)
    monkeypatch.setenv("CATALOG_ACCEPTED_REGIONS", "ru")
    monkeypatch.setenv("CATALOG_RATE_LIMIT_SALT", "s" * 32)
    settings = Settings()
    assert settings.database_url == "postgresql+asyncpg://u:p@h/db"
    assert settings.redis_url == "redis://h:6379/5"
    assert settings.environment == "staging"
    assert [(t.name, t.sha256) for t in settings.admin_tokens] == [("ops", digest("a" * 40))]
    assert [t.name for t in settings.ingest_tokens] == ["ru", "ru-next"]


def test_dev_allows_no_tokens() -> None:
    settings = Settings.model_validate({"database_url": DB})
    assert settings.environment == "dev"
    assert settings.admin_tokens == ()
    assert settings.ingest_tokens == ()


@pytest.mark.parametrize("environment", ["staging", "prod"])
def test_the_public_settings_need_no_tokens_in_strict_environments(environment: str) -> None:
    # The public service never authenticates anyone: it must not be given the digests at all.
    settings = Settings.model_validate(
        {"database_url": DB, "environment": environment, "rate_limit_salt": "s" * 32}
    )
    assert settings.admin_tokens == ()
    assert settings.ingest_tokens == ()


@pytest.mark.parametrize("environment", ["staging", "prod"])
def test_the_private_app_requires_both_token_lists_in_strict_environments(
    environment: str,
) -> None:
    good = f"ops:{digest('a' * 40)}"
    other = f"ru:{digest('b' * 40)}"
    base = {
        "database_url": DB,
        "environment": environment,
        "rate_limit_salt": "s" * 32,
        "accepted_regions": "ru",
    }
    with pytest.raises(ValueError, match="CATALOG_ADMIN_TOKENS"):
        Settings.model_validate({**base, "ingest_tokens": other}).require_service_tokens()
    with pytest.raises(ValueError, match="CATALOG_INGEST_TOKENS"):
        Settings.model_validate({**base, "admin_tokens": good}).require_service_tokens()
    Settings.model_validate(
        {**base, "admin_tokens": good, "ingest_tokens": other}
    ).require_service_tokens()


def test_the_private_app_refuses_to_start_without_tokens_in_staging() -> None:
    from catalog.private_app import create_private_app

    settings = Settings.model_validate(
        {"database_url": DB, "environment": "staging", "rate_limit_salt": "s" * 32}
    )
    with pytest.raises(ValueError, match="CATALOG_ADMIN_TOKENS"):
        create_private_app(settings)


def test_the_private_app_needs_no_tokens_in_dev() -> None:
    from catalog.private_app import create_private_app

    create_private_app(Settings.model_validate({"database_url": DB}))


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
    entry = f"ru:{digest('a' * 40)}"
    with pytest.raises(ValidationError, match="both"):
        Settings.model_validate(
            {
                "database_url": DB,
                "admin_tokens": entry,
                "ingest_tokens": entry,
                "accepted_regions": "ru",
            }
        )


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


@pytest.mark.parametrize("environment", ["staging", "prod"])
def test_strict_environments_require_an_explicit_rate_limit_salt(environment: str) -> None:
    # A per-process random salt would split the buckets of several processes and reset on restart.
    values = {
        "database_url": DB,
        "environment": environment,
        "admin_tokens": f"ops:{digest('a' * 40)}",
        "ingest_tokens": f"ru:{digest('b' * 40)}",
        "accepted_regions": "ru",
    }
    with pytest.raises(ValidationError, match="CATALOG_RATE_LIMIT_SALT"):
        Settings.model_validate(values)
    Settings.model_validate({**values, "rate_limit_salt": "s" * 32})


def test_a_blank_salt_means_unset_and_a_short_one_is_refused() -> None:
    # Compose passes ``CATALOG_RATE_LIMIT_SALT=`` when the variable is not set.
    blank = Settings.model_validate({"database_url": DB, "rate_limit_salt": ""})
    assert len(blank.rate_limit_salt.get_secret_value()) >= 32
    with pytest.raises(ValidationError):
        Settings.model_validate({"database_url": DB, "rate_limit_salt": "short"})


@pytest.mark.parametrize("name", ["importer", "ruby", "xru", "r", "eu2"])
def test_ingest_token_names_must_start_with_a_region(name: str) -> None:
    with pytest.raises(ValidationError, match="ru or eu"):
        Settings.model_validate(
            {
                "database_url": DB,
                "ingest_tokens": f"{name}:{digest('b' * 40)}",
                "accepted_regions": "ru,eu",
            }
        )


@pytest.mark.parametrize("name", ["ru", "eu", "ru-next", "eu_2"])
def test_rotation_names_of_a_region_are_accepted(name: str) -> None:
    settings = Settings.model_validate(
        {
            "database_url": DB,
            "ingest_tokens": f"{name}:{digest('b' * 40)}",
            "accepted_regions": "ru,eu",
        }
    )
    assert settings.ingest_tokens[0].name == name


def test_an_ingest_token_of_a_region_that_is_not_accepted_is_refused() -> None:
    with pytest.raises(ValidationError, match="CATALOG_ACCEPTED_REGIONS"):
        Settings.model_validate(
            {
                "database_url": DB,
                "ingest_tokens": f"eu:{digest('b' * 40)}",
                "accepted_regions": "ru",
            }
        )
    with pytest.raises(ValidationError, match="CATALOG_ACCEPTED_REGIONS"):
        Settings.model_validate({"database_url": DB, "ingest_tokens": f"ru:{digest('b' * 40)}"})


def test_accepted_regions_are_ru_and_eu_only_and_default_to_none() -> None:
    assert Settings.model_validate({"database_url": DB}).accepted_regions == ()
    assert Settings.model_validate(
        {"database_url": DB, "accepted_regions": " RU , eu "}
    ).accepted_regions == ("ru", "eu")
    with pytest.raises(ValidationError, match="ru and eu"):
        Settings.model_validate({"database_url": DB, "accepted_regions": "us"})
