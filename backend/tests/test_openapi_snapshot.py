"""The committed OpenAPI snapshot (spec/openapi.json) matches the code.

The Flutter client's contract test reads the snapshot, so a server schema change
that is not re-exported would let the client drift silently.
"""

from __future__ import annotations

import json
from pathlib import Path

from app.openapi_snapshot import SNAPSHOT_PATH, main, render_openapi


def test_snapshot_is_up_to_date() -> None:
    expected = render_openapi()
    actual = SNAPSHOT_PATH.read_text(encoding="utf-8") if SNAPSHOT_PATH.exists() else ""
    assert actual == expected, (
        "spec/openapi.json is stale: run `cd backend && uv run python -m app.openapi_snapshot`"
    )


def test_snapshot_is_region_independent_and_has_sync_schemas() -> None:
    schema = json.loads(render_openapi())
    assert schema["info"]["description"] == "PillPal backend API."
    names = set(schema["components"]["schemas"])
    assert {"PushRequest", "PullResponse", "TokenPair", "RegisterRequest"} <= names
    # Per-entity sync payloads are free-form in the route schema; the snapshot adds them.
    assert {"ProfileData", "MedicationData", "ScheduleData", "DoseEventData"} <= names


def test_main_writes_the_snapshot(tmp_path: Path) -> None:
    target = tmp_path / "openapi.json"
    main([str(target)])
    assert target.read_text(encoding="utf-8") == render_openapi()
