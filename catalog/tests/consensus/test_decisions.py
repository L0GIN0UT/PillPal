"""The decisions service: re-deciding a GTIN against the database (ADR 0014 sections 3 and 4).

The invariants of the public lookup (catalog/services/gtins.py) are tested through the public
API: ``promoted`` must resolve through the consensus ``gtins`` row, ``locked`` directly.
"""

from __future__ import annotations

import asyncio
import uuid

from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession

from catalog.domain.consensus import Thresholds
from catalog.services.decisions import redecide
from tests.api.seed import Seed
from tests.consensus.conftest import GTIN, OTHER_GTIN, Candidates

THRESHOLDS = Thresholds(promote_at=3, dispute_at=2)

Stored = tuple[str, uuid.UUID | None, str]


async def decide_now(engine: AsyncEngine, gtin: str = GTIN) -> None:
    async with AsyncSession(engine) as session, session.begin():
        await redecide(session, gtin, THRESHOLDS)


async def decision(engine: AsyncEngine, gtin: str = GTIN) -> Stored | None:
    async with engine.connect() as conn:
        row = (
            await conn.execute(
                text(
                    "SELECT status, product_id, decided_by FROM catalog.gtin_link_decisions "
                    "WHERE gtin = :g"
                ),
                {"g": gtin},
            )
        ).one_or_none()
    return None if row is None else (row.status, row.product_id, row.decided_by)


async def status_of(engine: AsyncEngine, gtin: str = GTIN) -> str | None:
    stored = await decision(engine, gtin)
    return None if stored is None else stored[0]


async def lookup(client: AsyncClient, gtin: str = GTIN) -> dict[str, object]:
    response = await client.post("/v1/gtins/lookup", json={"gtin": gtin})
    assert response.status_code == 200, response.text
    body: dict[str, object] = response.json()
    return body


async def test_promotion_writes_the_consensus_row_the_public_lookup_relies_on(
    client: AsyncClient, engine: AsyncEngine, seed: Seed, candidates: Candidates
) -> None:
    product = await seed.product("p-a", "Testamol")
    await candidates.put("ru", GTIN, product, 3)
    await decide_now(engine)
    assert await decision(engine) == ("promoted", product, "auto")
    body = await lookup(client)
    assert body["status"] == "found"
    assert body["product"]["id"] == str(product)  # type: ignore[index]
    assert body["package"]["gtins"] == [GTIN]  # type: ignore[index]


async def test_counts_are_summed_over_regions(
    engine: AsyncEngine, seed: Seed, candidates: Candidates
) -> None:
    product = await seed.product("p-a", "Testamol")
    await candidates.put("ru", GTIN, product, 2)
    await decide_now(engine)
    assert await status_of(engine) == "pending"
    await candidates.put("eu", GTIN, product, 2)
    await decide_now(engine)
    assert await status_of(engine) == "promoted"


async def test_a_competitor_at_two_disputes_and_the_lookup_says_so(
    client: AsyncClient, engine: AsyncEngine, seed: Seed, candidates: Candidates
) -> None:
    a = await seed.product("p-a", "Testamol")
    b = await seed.product("p-b", "Otheramol")
    await candidates.put("ru", GTIN, a, 3)
    await candidates.put("ru", GTIN, b, 2)
    await decide_now(engine)
    assert await decision(engine) == ("disputed", None, "auto")
    assert (await lookup(client))["status"] == "disputed"


async def test_a_dispute_withdraws_the_consensus_row_of_an_earlier_promotion(
    engine: AsyncEngine, seed: Seed, candidates: Candidates
) -> None:
    a = await seed.product("p-a", "Testamol")
    b = await seed.product("p-b", "Otheramol")
    await candidates.put("ru", GTIN, a, 3)
    await decide_now(engine)
    await candidates.put("ru", GTIN, b, 3)
    await decide_now(engine)
    assert await status_of(engine) == "disputed"
    async with engine.connect() as conn:
        live = (
            await conn.execute(
                text(
                    "SELECT count(*) FROM catalog.gtins WHERE gtin = :g AND source = 'consensus' "
                    "AND withdrawn_at IS NULL"
                ),
                {"g": GTIN},
            )
        ).scalar_one()
    assert live == 0


async def test_an_official_row_stands_against_two_young_accounts_and_is_disputed_at_n(
    client: AsyncClient, engine: AsyncEngine, seed: Seed, candidates: Candidates
) -> None:
    official = await seed.product("p-off", "Officialamol", packages=[("pack", [GTIN])])
    other = await seed.product("p-b", "Otheramol")
    await candidates.put("ru", GTIN, other, 2)
    await decide_now(engine)
    assert await decision(engine) == ("promoted", official, "auto")
    assert (await lookup(client))["product"]["id"] == str(official)  # type: ignore[index]
    await candidates.put("ru", GTIN, other, 3)
    await decide_now(engine)
    assert await status_of(engine) == "disputed"
    assert (await lookup(client))["status"] == "disputed"


async def test_promotion_is_sticky_when_the_counts_vanish(
    client: AsyncClient, engine: AsyncEngine, seed: Seed, candidates: Candidates
) -> None:
    product = await seed.product("p-a", "Testamol")
    await candidates.put("ru", GTIN, product, 3)
    await decide_now(engine)
    await candidates.clear()
    await decide_now(engine)
    assert await decision(engine) == ("promoted", product, "auto")
    assert (await lookup(client))["status"] == "found"


async def test_a_withdrawn_product_gets_no_votes(
    engine: AsyncEngine, seed: Seed, candidates: Candidates
) -> None:
    gone = await seed.product("p-gone", "Gonamol", withdrawn=True)
    await candidates.put("ru", GTIN, gone, 5)
    await decide_now(engine)
    assert await decision(engine) is None  # nothing live to decide on


async def test_a_gtin_nobody_confirmed_gets_no_decision_row(engine: AsyncEngine) -> None:
    await decide_now(engine, OTHER_GTIN)
    assert await decision(engine, OTHER_GTIN) is None


async def test_concurrent_decisions_for_one_gtin_do_not_collide(
    engine: AsyncEngine, seed: Seed, candidates: Candidates
) -> None:
    product = await seed.product("p-a", "Testamol")
    await candidates.put("ru", GTIN, product, 3)
    await asyncio.gather(*(decide_now(engine) for _ in range(4)))
    assert await decision(engine) == ("promoted", product, "auto")
