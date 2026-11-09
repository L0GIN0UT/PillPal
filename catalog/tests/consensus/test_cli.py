"""``python -m catalog.admin``: the same decisions for operators without HTTP access."""

from __future__ import annotations

import asyncio
import json
import subprocess
import sys

import pytest
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from catalog.admin import cli
from catalog.config import Settings
from tests.api.seed import Seed
from tests.conftest import make_settings
from tests.consensus.conftest import GTIN, Candidates
from tests.helpers import CATALOG_DIR


async def run_cli(argv: list[str], settings: Settings | None = None) -> int:
    # The CLI owns its event loop, as it does from a shell.
    return await asyncio.to_thread(cli.main, argv, settings or make_settings())


async def test_disputes_list_prints_gtin_candidates_and_counts_only(
    seed: Seed, candidates: Candidates, capsys: pytest.CaptureFixture[str]
) -> None:
    a = await seed.product("p-a", "Testamol")
    b = await seed.product("p-b", "Otheramol")
    await candidates.put("ru", GTIN, a, 3)
    await candidates.put("ru", GTIN, b, 2)
    await seed.decision(GTIN, "disputed")
    assert await run_cli(["disputes", "list"]) == 0
    lines = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert [line["gtin"] for line in lines] == [GTIN]
    assert [(c["name"], c["confirmations"]) for c in lines[0]["candidates"]] == [
        ("Testamol", 3),
        ("Otheramol", 2),
    ]


async def test_resolve_applies_the_decision_and_audits_it_as_cli(
    seed: Seed, engine: AsyncEngine, capsys: pytest.CaptureFixture[str]
) -> None:
    a = await seed.product("p-a", "Testamol")
    code = await run_cli(["resolve", GTIN, "--action", "lock", "--product", str(a)])
    assert code == 0
    assert json.loads(capsys.readouterr().out) == {
        "gtin": GTIN,
        "status": "locked",
        "product_id": str(a),
        "decided_by": "admin",
        "reason_code": "admin_lock",
    }
    async with engine.connect() as conn:
        rows = (
            await conn.execute(text("SELECT admin_name, action, gtin FROM catalog.admin_audit"))
        ).all()
    assert [tuple(r) for r in rows] == [("cli", "lock", GTIN)]


@pytest.mark.parametrize(
    ("argv", "code", "message"),
    [
        (["resolve", "12", "--action", "reject"], 2, "invalid_gtin"),
        (["resolve", "02000000000008", "--action", "reject"], 2, "invalid_gtin"),
        (["resolve", GTIN, "--action", "lock"], 1, "product_required"),
        (
            [
                "resolve",
                GTIN,
                "--action",
                "lock",
                "--product",
                "00000000-0000-0000-0000-000000000009",
            ],
            1,
            "unknown_product",
        ),
    ],
)
async def test_errors_are_stable_codes_on_stderr(
    seed: Seed,
    capsys: pytest.CaptureFixture[str],
    argv: list[str],
    code: int,
    message: str,
) -> None:
    assert await run_cli(argv) == code
    captured = capsys.readouterr()
    assert captured.err.strip() == f"error: {message}"
    assert captured.out == ""


def test_the_module_runs_as_a_command() -> None:
    result = subprocess.run(
        [sys.executable, "-m", "catalog.admin", "--help"],
        cwd=CATALOG_DIR,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0
    assert "disputes" in result.stdout
