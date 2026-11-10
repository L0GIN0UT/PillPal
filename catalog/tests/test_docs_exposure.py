"""The interactive docs and the schema are for development: strict environments publish none."""

from __future__ import annotations

import pytest
from httpx import ASGITransport, AsyncClient

from catalog.main import create_app
from tests.conftest import make_settings


@pytest.mark.parametrize("path", ["/docs", "/redoc", "/openapi.json"])
@pytest.mark.parametrize("environment", ["staging", "prod"])
async def test_strict_environments_serve_no_docs_or_schema(environment: str, path: str) -> None:
    app = create_app(make_settings(environment=environment))
    transport = ASGITransport(app=app, raise_app_exceptions=False)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        assert (await client.get(path)).status_code == 404


@pytest.mark.parametrize("environment", ["dev", "test"])
async def test_development_keeps_the_docs(environment: str) -> None:
    app = create_app(make_settings(environment=environment))
    transport = ASGITransport(app=app, raise_app_exceptions=False)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        assert (await client.get("/openapi.json")).status_code == 200


def test_the_schema_snapshot_can_still_be_rendered() -> None:
    from catalog.openapi_snapshot import render_openapi

    assert '"/v1/search"' in render_openapi()
