"""Static checks of the image definition (the image itself is built by CI)."""

from __future__ import annotations

import re

from tests.helpers import CATALOG_DIR

DOCKERFILE = (CATALOG_DIR / "Dockerfile").read_text(encoding="utf-8")


def _instructions(name: str) -> list[str]:
    return [m.group(1).strip() for m in re.finditer(rf"^{name}\s+(.+)$", DOCKERFILE, re.MULTILINE)]


def test_runtime_stage_runs_as_a_non_root_user() -> None:
    users = _instructions("USER")
    assert users, "no USER instruction: the container would run as root"
    assert users[-1] not in {"root", "0", "0:0", "root:root"}
    # The USER comes after the last stage starts, i.e. it applies to the runtime image.
    assert DOCKERFILE.rindex("USER ") > DOCKERFILE.rindex("FROM ")


def test_the_non_root_user_exists_with_a_fixed_non_zero_uid() -> None:
    assert re.search(r"useradd[^\n]*--uid\s+[1-9][0-9]*", DOCKERFILE.replace("\\\n", " "))


def test_no_secrets_in_the_image_definition() -> None:
    assert not re.search(
        r"^(ARG|ENV)\s+\S*(SECRET|TOKEN|PASSWORD|DATABASE_URL)", DOCKERFILE, re.M | re.I
    )


def test_migrations_run_only_on_request() -> None:
    assert "RUN_MIGRATIONS=0" in DOCKERFILE
    assert 'if [ "${RUN_MIGRATIONS:-0}" = "1" ]' in DOCKERFILE


def test_serves_the_catalog_app_without_uvicorns_own_access_log() -> None:
    cmd = _instructions("CMD")[0]
    assert "catalog.main:app" in cmd
    assert "--no-access-log" in cmd


def test_proxy_headers_are_trusted_from_nobody_by_default() -> None:
    # uvicorn would otherwise trust loopback; the proxy subnet is an explicit deployment decision.
    assert re.search(r'^ENV\s+.*FORWARDED_ALLOW_IPS=""', DOCKERFILE, re.MULTILINE)
