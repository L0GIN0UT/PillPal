"""The committed OpenAPI snapshot (catalog/openapi.json) matches the code.

The app's catalog client is generated against this contract (milestone 4.9), so a route or schema
change that is not re-exported would let the client drift silently.
"""

from __future__ import annotations

import json
from pathlib import Path

from catalog.openapi_snapshot import SNAPSHOT_PATH, main, render_openapi


def test_snapshot_is_up_to_date() -> None:
    actual = SNAPSHOT_PATH.read_text(encoding="utf-8") if SNAPSHOT_PATH.exists() else ""
    assert actual == render_openapi(), (
        "catalog/openapi.json is stale: run `uv run python -m catalog.openapi_snapshot` in catalog/"
    )


def test_snapshot_describes_only_the_public_surface() -> None:
    schema = json.loads(render_openapi())
    paths = schema["paths"]
    assert set(paths) == {
        "/healthz",
        "/readyz",
        "/v1/search",
        "/v1/gtins/lookup",
        "/v1/products/get",
        "/v1/sources",
    }
    # Lookups are POST with JSON bodies so that what people type never lands in a URL (ADR 0015).
    for path in ("/v1/search", "/v1/gtins/lookup", "/v1/products/get"):
        assert set(paths[path]) == {"post"}
    assert set(paths["/v1/sources"]) == {"get"}
    assert "securitySchemes" not in schema.get("components", {})  # no credentials anywhere


def test_main_writes_the_snapshot(tmp_path: Path) -> None:
    target = tmp_path / "openapi.json"
    main([str(target)])
    assert target.read_text(encoding="utf-8") == render_openapi()
