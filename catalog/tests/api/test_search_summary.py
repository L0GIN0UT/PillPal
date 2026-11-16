"""The result summary (substance labels) and the typo fallback of POST /v1/search.

Regression tests of the staging incident on the full ESKLP: the labels of each result were a
correlated subquery that the planner re-ran per row (most of a 1 s query), and the trigram path
aggregated ~10k typo candidates for a query that already had plenty of exact matches.
"""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager
from decimal import Decimal
from typing import Any

from httpx import AsyncClient
from sqlalchemy import event, text
from sqlalchemy.ext.asyncio import AsyncEngine

from catalog.importers.ids import product_id
from catalog.services import search as search_service
from catalog.services.search import TEXT_STATEMENTS
from tests.api.seed import Ingredient, Seed


async def results(client: AsyncClient, q: str, **body: Any) -> list[dict[str, Any]]:
    response = await client.post("/v1/search", json={"q": q, "lang": "en", **body})
    assert response.status_code == 200, response.text
    found: list[dict[str, Any]] = response.json()["results"]
    return found


async def mixed_catalog(seed: Seed) -> None:
    """Products with several, one and no ingredients; a substance without a Russian name."""
    zeta = await seed.substance("zeta", "Zetamine", "Альфамин")
    alpha = await seed.substance("alpha", "Alphazole", "Ятразол")
    only_en = await seed.substance("only-en", "Betaprofen", None)
    trio = await seed.composition(
        "trio",
        [
            Ingredient(zeta, Decimal("1"), "mg"),
            Ingredient(alpha, Decimal("2"), "mg"),
            Ingredient(only_en, Decimal("3"), "mg"),
        ],
    )
    solo = await seed.composition("solo", [Ingredient(alpha, Decimal("2"), "mg")], form_ru=None)
    await seed.product("trio", "Summarol Trio", market="ru", composition=trio)
    await seed.product("solo", "Summarol Solo", market="us", composition=solo, withdrawn=True)
    await seed.product("bare", "Summarol Bare", market="eu", composition=None)


async def test_labels_are_sorted_per_language_with_fallback(
    client: AsyncClient, seed: Seed
) -> None:
    await mixed_catalog(seed)
    en = {r["name"]: r for r in await results(client, "summarol", market="ru")}
    assert en["Summarol Trio"]["substances"] == ["Alphazole", "Betaprofen", "Zetamine"]
    assert en["Summarol Solo"]["substances"] == ["Alphazole"]
    assert en["Summarol Bare"]["substances"] == []
    assert en["Summarol Bare"]["form"] is None

    ru = {r["name"]: r for r in await results(client, "summarol", lang="ru", market="ru")}
    # Betaprofen has no Russian name: the English one stands in, sorted with the others.
    assert ru["Summarol Trio"]["substances"] == ["Betaprofen", "Альфамин", "Ятразол"]
    assert ru["Summarol Solo"]["form"] == "tablet"  # no Russian form name either


async def test_order_and_withdrawn_flag_survive_the_summary(
    client: AsyncClient, seed: Seed
) -> None:
    await mixed_catalog(seed)
    found = await results(client, "summarol", market="ru")
    # Own market first, withdrawn last.
    assert [r["name"] for r in found] == ["Summarol Trio", "Summarol Bare", "Summarol Solo"]
    assert [r["withdrawn"] for r in found] == [False, False, True]


def _subplans(node: dict[str, Any]) -> list[str]:
    own = [node["Node Type"]] if node.get("Parent Relationship") == "SubPlan" else []
    return own + [name for child in node.get("Plans", []) for name in _subplans(child)]


async def test_the_summary_has_no_correlated_subplan(engine: AsyncEngine, seed: Seed) -> None:
    del seed  # an empty catalog is enough to plan the statements
    params = {
        "qn": "summarol",
        "tsq": "'summarol':*",
        "market": "ru",
        "lang": "en",
        "limit": 20,
        "entry_cap": 200,
        "substance_cap": 25,
        "ids": [],
    }
    async with engine.connect() as conn:
        for statement in (*TEXT_STATEMENTS["product"], search_service._BY_IDS):
            explain = text("EXPLAIN (FORMAT JSON) " + statement.text)
            names = explain.compile().params
            plan = (
                await conn.execute(explain, {k: v for k, v in params.items() if k in names})
            ).scalar_one()
            assert _subplans(plan[0]["Plan"]) == []


def test_only_the_typo_pass_carries_the_trigram_predicate() -> None:
    for kind, (exact, typo) in TEXT_STATEMENTS.items():
        assert "<%" not in exact.text, kind
        assert "<%" in typo.text, kind
        assert ":trgm" not in exact.text + typo.text, kind


@contextmanager
def trigram_statements(engine: AsyncEngine) -> Iterator[list[str]]:
    """Statements with the trigram predicate that reach PostgreSQL while the block runs."""
    seen: list[str] = []

    def record(_conn: object, _cursor: object, statement: str, *_: object) -> None:
        if "<%" in statement:
            seen.append(statement)

    event.listen(engine.sync_engine, "before_cursor_execute", record)
    try:
        yield seen
    finally:
        event.remove(engine.sync_engine, "before_cursor_execute", record)


def by_id(*keys: str) -> list[str]:
    return [
        str(product_id("openfda_ndc", key))
        for key in sorted(keys, key=lambda key: str(product_id("openfda_ndc", key)))
    ]


async def test_typos_fill_up_a_page_that_exact_matches_leave_short(
    client: AsyncClient, seed: Seed
) -> None:
    await seed.product("exact-1", "Testamol One", market="ru")
    await seed.product("typo", "Tesstamol", market="ru")
    found = [r["name"] for r in await results(client, "testamol", market="ru")]
    assert found == ["Testamol One", "Tesstamol"]  # the better score first, typo included


async def test_typos_are_not_searched_when_active_own_market_matches_fill_the_page(
    client: AsyncClient, seed: Seed, engine: AsyncEngine
) -> None:
    await seed.product("exact-1", "Testamol One", market="ru")
    await seed.product("exact-2", "Testamol Two", market="ru")
    await seed.product("typo", "Tesstamol", market="ru")
    with trigram_statements(engine) as seen:
        found = await results(client, "testamol", market="ru", limit=2)
    assert [r["id"] for r in found] == by_id("exact-1", "exact-2")  # equal scores: id order
    assert seen == []


async def test_a_typo_outranks_withdrawn_exact_matches(client: AsyncClient, seed: Seed) -> None:
    await seed.product("old-1", "Testamol One", withdrawn=True)
    await seed.product("old-2", "Testamol Two", withdrawn=True)
    await seed.product("typo", "Tesstamol")
    found = [r["name"] for r in await results(client, "testamol", limit=2)]
    assert found[0] == "Tesstamol"


async def test_an_own_market_typo_outranks_foreign_exact_matches(
    client: AsyncClient, seed: Seed
) -> None:
    await seed.product("exact-1", "Testamol One", market="us")
    await seed.product("exact-2", "Testamol Two", market="us")
    await seed.product("typo", "Tesstamol", market="ru")
    found = [r["name"] for r in await results(client, "testamol", market="ru", limit=2)]
    assert found[0] == "Tesstamol"


async def test_substance_typos_follow_the_same_rule(
    client: AsyncClient, seed: Seed, engine: AsyncEngine
) -> None:
    await seed.substance("exact", "Ibuprofen", market="ru")
    await seed.substance("typo", "Ibuprofem", market="ru")
    await seed.substance("foreign", "Ibuprofen Forte", market="us")
    with trigram_statements(engine) as seen:
        one = await results(client, "ibuprofen", kind="substance", market="ru", limit=1)
    assert [r["name"] for r in one] == ["Ibuprofen"]
    assert seen == []
    two = await results(client, "ibuprofen", kind="substance", market="ru", limit=2)
    assert [r["name"] for r in two] == ["Ibuprofen", "Ibuprofem"]
