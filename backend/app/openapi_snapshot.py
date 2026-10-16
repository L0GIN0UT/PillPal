"""Export the OpenAPI document to ``spec/openapi.json`` (the client contract snapshot).

Run ``uv run python -m app.openapi_snapshot`` after changing any route or schema;
``tests/test_openapi_snapshot.py`` fails while the committed snapshot is stale and
the Flutter app's contract test reads it.
"""

from __future__ import annotations

import json
import sys
from collections.abc import Sequence
from pathlib import Path

from pydantic import BaseModel, SecretStr
from pydantic.json_schema import models_json_schema

from app.config import Settings
from app.main import create_app
from app.schemas.entities import DoseEventData, MedicationData, ProfileData, ScheduleData

SNAPSHOT_PATH = Path(__file__).resolve().parents[2] / "spec" / "openapi.json"

# Placeholders only: building the schema opens no connections, and the region is
# fixed so the snapshot is identical for every deployment.
_SNAPSHOT_SETTINGS = {
    "region": "ru",
    "environment": "test",
    "database_url": "postgresql+asyncpg://snapshot:snapshot@localhost:5432/snapshot",
    "jwt_secret": SecretStr("snapshot-only-not-a-secret-snapshot-only"),
}


# Sync push ``data`` is free-form in the route schema (validated per entity in the
# service), so the per-entity payload models are added to the snapshot explicitly.
_SYNC_DATA_MODELS: tuple[type[BaseModel], ...] = (
    ProfileData,
    MedicationData,
    ScheduleData,
    DoseEventData,
)


def _sync_data_schemas() -> dict[str, object]:
    _, document = models_json_schema(
        [(model, "validation") for model in _SYNC_DATA_MODELS],
        ref_template="#/components/schemas/{model}",
    )
    defs: dict[str, object] = document.get("$defs", {})
    return defs


def render_openapi() -> str:
    app = create_app(Settings.model_validate(_SNAPSHOT_SETTINGS))
    schema = app.openapi()
    schema["info"]["description"] = "PillPal backend API."
    schema["components"]["schemas"].update(_sync_data_schemas())
    return json.dumps(schema, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def main(argv: Sequence[str] | None = None) -> None:
    args = list(sys.argv[1:] if argv is None else argv)
    target = Path(args[0]) if args else SNAPSHOT_PATH
    target.write_text(render_openapi(), encoding="utf-8")


if __name__ == "__main__":  # pragma: no cover
    main()
