"""Export the OpenAPI document to ``catalog/openapi.json`` (the client contract snapshot).

Run ``uv run python -m catalog.openapi_snapshot`` after changing any route or schema;
``tests/test_openapi_snapshot.py`` fails while the committed snapshot is stale.
"""

from __future__ import annotations

import json
import sys
from collections.abc import Sequence
from pathlib import Path

from catalog.config import Settings
from catalog.main import create_app

SNAPSHOT_PATH = Path(__file__).resolve().parents[1] / "openapi.json"

# Placeholders only: building the schema opens no connections.
_SNAPSHOT_SETTINGS = {
    "database_url": "postgresql+asyncpg://snapshot:snapshot@localhost:5432/snapshot",
    "environment": "test",
}


def render_openapi() -> str:
    app = create_app(Settings.model_validate(_SNAPSHOT_SETTINGS))
    return json.dumps(app.openapi(), indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def main(argv: Sequence[str] | None = None) -> None:
    args = list(sys.argv[1:] if argv is None else argv)
    target = Path(args[0]) if args else SNAPSHOT_PATH
    target.write_text(render_openapi(), encoding="utf-8", newline="\n")


if __name__ == "__main__":  # pragma: no cover
    main()
