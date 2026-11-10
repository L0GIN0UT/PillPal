"""The compose definition must keep the catalog away from the backend's credentials (ADR 0011)."""

from __future__ import annotations

from typing import Any

import yaml

from tests.helpers import CATALOG_DIR

REPO = CATALOG_DIR.parent
ALLOWED_ENV = {"ENVIRONMENT", "LOG_LEVEL", "RUN_MIGRATIONS", "FORWARDED_ALLOW_IPS"}


def _service(name: str) -> dict[str, Any]:
    compose = yaml.safe_load((REPO / "infra" / "docker-compose.yml").read_text(encoding="utf-8"))
    return compose["services"][name]  # type: ignore[no-any-return]


def test_catalog_service_does_not_receive_the_whole_env_file() -> None:
    service = _service("catalog")
    assert "env_file" not in service
    unexpected = {k for k in service["environment"] if not k.startswith("CATALOG_")} - ALLOWED_ENV
    assert unexpected == set()


def test_catalog_service_connects_with_its_own_role_not_the_superuser() -> None:
    url = _service("catalog")["environment"]["CATALOG_DATABASE_URL"]
    assert "@postgres:5432/" in url
    credentials = url.split("://", 1)[1].split("@", 1)[0]
    assert credentials.startswith("catalog:${CATALOG_DB_PASSWORD")
    assert "POSTGRES_USER" not in url
    assert "POSTGRES_PASSWORD" not in url


def test_proxy_trust_is_explicit_and_documented_without_a_wildcard() -> None:
    forwarded = _service("catalog")["environment"]["FORWARDED_ALLOW_IPS"]
    assert "*" not in forwarded
    readme = (CATALOG_DIR / "README.md").read_text(encoding="utf-8")
    assert "FORWARDED_ALLOW_IPS" in readme
    assert "never `*`" in readme


def test_env_example_has_the_catalog_db_password() -> None:
    example = (REPO / "infra" / ".env.example").read_text(encoding="utf-8")
    assert "\nCATALOG_DB_PASSWORD=CHANGE_ME" in example


def _staging(name: str) -> dict[str, Any]:
    compose = yaml.safe_load(
        (REPO / "infra" / "staging" / "docker-compose.yml").read_text(encoding="utf-8")
    )
    return compose["services"][name]  # type: ignore[no-any-return]


def test_staging_public_catalog_holds_no_token_digests_and_a_read_only_role() -> None:
    env = _staging("catalog")["environment"]
    assert "CATALOG_ADMIN_TOKENS" not in env
    assert "CATALOG_INGEST_TOKENS" not in env
    assert "@catalog-postgres:5432/" in env["CATALOG_DATABASE_URL"]
    assert env["CATALOG_DATABASE_URL"].split("://", 1)[1].startswith("${CATALOG_READER_USER")
    assert "*" not in env["FORWARDED_ALLOW_IPS"]
    private = _staging("catalog-private")["environment"]
    assert "CATALOG_ADMIN_TOKENS" in private
    assert "CATALOG_INGEST_TOKENS" in private
    assert private["FORWARDED_ALLOW_IPS"] == ""
    assert "ports" not in _staging("catalog-private")


def test_staging_catalog_has_its_own_redis_without_ports_or_disk() -> None:
    redis = _staging("catalog-redis")
    assert "ports" not in redis
    assert "volumes" not in redis
    assert "appendonly no" in " ".join(redis["command"])
    for name in ("catalog", "catalog-private", "catalog-tools"):
        service = _staging(name)
        assert "@catalog-redis:" in service["environment"]["CATALOG_REDIS_URL"]
        assert "redis" not in service["depends_on"]
