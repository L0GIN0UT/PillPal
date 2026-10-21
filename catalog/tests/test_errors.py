from __future__ import annotations

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from pydantic import BaseModel, ConfigDict

from catalog.errors import AppError
from catalog.main import create_app
from tests.conftest import make_settings


class Body(BaseModel):
    model_config = ConfigDict(extra="forbid")
    q: str


@pytest.fixture
async def probe() -> AsyncClient:  # type: ignore[misc]
    app: FastAPI = create_app(make_settings())

    @app.post("/_probe/validate")
    async def validate(body: Body) -> dict[str, str]:
        return {"q": body.q}

    @app.get("/_probe/teapot")
    async def teapot() -> None:
        raise AppError(418, "teapot", "I am a teapot")

    @app.get("/_probe/boom")
    async def boom() -> None:
        raise RuntimeError("secret-internal-detail")

    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://test") as c:
            yield c  # type: ignore[misc]


async def test_unknown_route_is_the_envelope(probe: AsyncClient) -> None:
    response = await probe.get("/nope")
    assert response.status_code == 404
    assert response.json() == {"error": {"code": "not_found", "message": "Not found"}}


async def test_wrong_method_is_the_envelope(probe: AsyncClient) -> None:
    response = await probe.post("/healthz")
    assert response.status_code == 405
    assert response.json()["error"]["code"] == "method_not_allowed"


async def test_app_error_is_the_envelope(probe: AsyncClient) -> None:
    response = await probe.get("/_probe/teapot")
    assert response.status_code == 418
    assert response.json() == {"error": {"code": "teapot", "message": "I am a teapot"}}


async def test_validation_error_exposes_neither_input_nor_field_names(probe: AsyncClient) -> None:
    # A client-chosen key ("paracetamol") appears in pydantic's loc for extra fields.
    response = await probe.post("/_probe/validate", json={"q": 5, "paracetamol": "x"})
    assert response.status_code == 422
    body = response.json()
    assert body["error"]["code"] == "validation_error"
    assert "paracetamol" not in response.text
    assert body["error"]["details"]
    for detail in body["error"]["details"]:
        assert set(detail) == {"loc", "type"}
        assert detail["loc"] == ["body"]


async def test_unhandled_exception_is_a_500_envelope_without_details(probe: AsyncClient) -> None:
    response = await probe.get("/_probe/boom")
    assert response.status_code == 500
    assert response.json() == {
        "error": {"code": "internal_error", "message": "Internal server error"}
    }
    assert "secret-internal-detail" not in response.text
    assert response.headers["x-request-id"]
