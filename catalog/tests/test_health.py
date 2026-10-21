from __future__ import annotations

from httpx import ASGITransport, AsyncClient

from catalog.main import create_app
from tests.conftest import make_settings


async def test_healthz_does_not_touch_dependencies(client: AsyncClient) -> None:
    response = await client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


async def test_readyz_pings_the_database(client: AsyncClient) -> None:
    response = await client.get("/readyz")
    assert response.status_code == 200
    assert response.json() == {"status": "ok", "checks": {"database": "ok"}}


async def test_readyz_is_503_when_the_database_is_down() -> None:
    # A closed port: a real connection failure, not a mock.
    settings = make_settings(database_url="postgresql+asyncpg://postgres:postgres@127.0.0.1:1/none")
    app = create_app(settings)
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as c:
            response = await c.get("/readyz")
            assert (await c.get("/healthz")).status_code == 200
    assert response.status_code == 503
    assert response.json()["error"]["code"] == "not_ready"


async def test_no_cors_headers_even_for_a_cross_origin_preflight(client: AsyncClient) -> None:
    response = await client.options(
        "/healthz",
        headers={"Origin": "https://evil.example", "Access-Control-Request-Method": "GET"},
    )
    assert "access-control-allow-origin" not in response.headers
