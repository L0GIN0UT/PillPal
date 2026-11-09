"""The backend's GTIN module is a copy of the catalog reference's shared part.

The vectors are the contract; this cheap guard additionally catches a one-sided edit. It reads
the catalog source from the repository checkout (no import: the services are separate packages).
"""

from __future__ import annotations

import ast
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
BACKEND = ROOT / "backend" / "app" / "domain" / "gtin.py"
CATALOG = ROOT / "catalog" / "catalog" / "domain" / "gtin.py"
# Defined only by the catalog (the GS1 parser's code, the GTIN-13 helper) or documented there.
CATALOG_ONLY = {"GtinErrorCode", "gtin14_to_gtin13"}


def _definitions(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for node in ast.parse(path.read_text(encoding="utf-8")).body:
        if isinstance(node, ast.FunctionDef | ast.ClassDef):
            result[node.name] = ast.dump(node)
        elif isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
            result[node.target.id] = ast.dump(node)
    return result


@pytest.mark.skipif(not CATALOG.is_file(), reason="catalog sources are not in this checkout")
def test_shared_definitions_are_identical() -> None:
    backend, catalog = _definitions(BACKEND), _definitions(CATALOG)
    shared = (backend.keys() & catalog.keys()) - CATALOG_ONLY
    assert {"normalize", "classify", "check_digit", "ndc_to_gtin14", "Gtin"} <= shared
    assert [name for name in sorted(shared) if backend[name] != catalog[name]] == []
    assert sorted(catalog.keys() - backend.keys() - CATALOG_ONLY) == []
