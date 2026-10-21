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
