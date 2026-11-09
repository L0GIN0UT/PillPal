"""PUT /internal/v1/regions/{region}/gtin-confirmations (ADR 0014 section 3)."""

from __future__ import annotations

import uuid
from typing import Any

from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.api.seed import Seed
from tests.consensus.conftest import (
    ADMIN_SECRET,
    EU_SECRET,
    GTIN,
    OTHER_GTIN,
    RU_NEXT_SECRET,
    RU_SECRET,
    Candidates,
    gtin14,
    private_app_client,
    private_settings,
)
from tests.consensus.helpers import bearer, item, put

RESTRICTED = "02000000000008"


async def stored(candidates: Candidates) -> list[tuple[str, str, uuid.UUID, int]]:
    return await candidates.rows()


# --- authentication and the region binding --------------------------------------------------


async def test_a_missing_or_wrong_token_is_401(private_client: AsyncClient) -> None:
    body = {"generation": 1, "page": 0, "complete": True, "items": []}
    url = "/internal/v1/regions/ru/gtin-confirmations"
    assert (await private_client.put(url, json=body)).status_code == 401
    assert (await private_client.put(url, json=body, headers=bearer("nope"))).status_code == 401
    basic = {"Authorization": f"Basic {RU_SECRET}"}
    assert (await private_client.put(url, json=body, headers=basic)).status_code == 401
    answer = await private_client.put(url, json=body, headers=bearer("nope"))
    assert answer.json()["error"]["code"] == "unauthorized"
    assert answer.headers["www-authenticate"] == "Bearer"


async def test_a_token_of_another_region_is_403(
    private_client: AsyncClient, candidates: Candidates
) -> None:
    answer = await put(private_client, [], region="eu", secret=RU_SECRET)
    assert answer.status_code == 403
    assert answer.json()["error"]["code"] == "forbidden"
    assert await stored(candidates) == []


async def test_a_rotation_token_of_the_same_region_is_accepted(
    private_client: AsyncClient, seed: Seed
) -> None:
    assert (await put(private_client, [], secret=RU_NEXT_SECRET)).status_code == 200


async def test_an_admin_token_cannot_ingest(private_client: AsyncClient) -> None:
    assert (await put(private_client, [], secret=ADMIN_SECRET)).status_code == 401


# --- validation -----------------------------------------------------------------------------


async def test_validation_errors_are_422_and_echo_nothing(private_client: AsyncClient) -> None:
    product = uuid.uuid4()
    bad_bodies = [
        {"generation": 0, "page": 0, "complete": True, "items": []},
        {"generation": 1, "page": -1, "complete": True, "items": []},
        {"generation": 1, "page": 0, "complete": True, "items": [item(GTIN, product, 1)]},
        {"generation": 1, "page": 0, "complete": True, "items": [item("123", product)]},
        {"generation": 1, "page": 0, "complete": True, "items": [], "user": "someone"},
        {
            "generation": 1,
            "page": 0,
            "complete": True,
            "items": [{**item(GTIN, product), "device_id": "x"}],
        },
    ]
    for body in bad_bodies:
        answer = await private_client.put(
            "/internal/v1/regions/ru/gtin-confirmations", json=body, headers=bearer()
        )
        assert answer.status_code == 422, body
        assert "someone" not in answer.text
    unknown_region = await put(private_client, [], region="xx")
    assert unknown_region.status_code == 422


async def test_a_page_over_the_item_cap_is_413(seed: Seed, clean_redis: None) -> None:
    product = await seed.product("p-a", "Testamol")
    items = [item(gtin14(f"046070123{n:04d}"), product) for n in range(1, 6)]
    async with private_app_client(private_settings(ingest_page_max_items=4)) as small:
        answer = await put(small, items)
    assert answer.status_code == 413
    assert answer.json()["error"]["code"] == "payload_too_large"


async def test_a_snapshot_over_the_total_cap_is_413_and_nothing_is_committed(
    seed: Seed, candidates: Candidates, clean_redis: None
) -> None:
    product = await seed.product("p-a", "Testamol")
    async with private_app_client(private_settings(ingest_max_items=3)) as small:
        first = await put(
            small, [item(gtin14(f"046070123{n:04d}"), product) for n in (1, 2)], complete=False
        )
        second = await put(
            small, [item(gtin14(f"046070123{n:04d}"), product) for n in (3, 4)], page=1
        )
    assert first.status_code == 200
    assert second.status_code == 413
    assert await stored(candidates) == []


# --- staging, swap and the rule of completeness ----------------------------------------------


async def test_pages_are_staged_and_swapped_only_on_complete(
    private_client: AsyncClient, seed: Seed, candidates: Candidates
) -> None:
    a = await seed.product("p-a", "Testamol")
    b = await seed.product("p-b", "Otheramol")
    first = await put(private_client, [item(GTIN, a, 3)], complete=False)
    assert (first.status_code, first.json()["status"]) == (200, "staged")
    assert await stored(candidates) == []  # nothing visible before the last page
    last = await put(private_client, [item(OTHER_GTIN, b, 2)], page=1)
    assert (last.status_code, last.json()["status"]) == (200, "committed")
    assert await stored(candidates) == sorted(
        [("ru", GTIN, a, 3), ("ru", OTHER_GTIN, b, 2)], key=lambda r: (r[0], r[1], r[2])
    )


async def test_a_complete_page_with_a_missing_page_is_refused_and_keeps_the_old_snapshot(
    private_client: AsyncClient, seed: Seed, candidates: Candidates
) -> None:
    a = await seed.product("p-a", "Testamol")
    assert (await put(private_client, [item(GTIN, a, 2)], generation=1)).status_code == 200
    gap = await put(private_client, [], generation=2, page=2)  # pages 0 and 1 never arrived
    assert gap.status_code == 409
    assert gap.json()["error"]["code"] == "snapshot_incomplete"
    assert await stored(candidates) == [("ru", GTIN, a, 2)]


async def test_a_new_snapshot_replaces_the_region_and_lowers_counts(
    private_client: AsyncClient, seed: Seed, candidates: Candidates
) -> None:
    a = await seed.product("p-a", "Testamol")
    await put(private_client, [item(GTIN, a, 5), item(OTHER_GTIN, a, 2)], generation=1)
    await put(private_client, [item(GTIN, a, 2)], generation=2)
    assert await stored(candidates) == [("ru", GTIN, a, 2)]  # erasure lowered a count, one is gone
    await put(private_client, [], generation=3)
    assert await stored(candidates) == []


async def test_a_snapshot_of_one_region_leaves_the_other_regions_rows(
    private_client: AsyncClient, seed: Seed, candidates: Candidates
) -> None:
    a = await seed.product("p-a", "Testamol")
    await candidates.put("eu", GTIN, a, 4)
    await put(private_client, [item(GTIN, a, 2)], generation=1)
    assert (await put(private_client, [], region="eu", secret=EU_SECRET)).status_code == 200
    assert await stored(candidates) == [("ru", GTIN, a, 2)]


async def test_replaying_a_page_or_a_committed_snapshot_is_idempotent(
    private_client: AsyncClient, seed: Seed, candidates: Candidates
) -> None:
    a = await seed.product("p-a", "Testamol")
    staged = await put(private_client, [item(GTIN, a, 2)], complete=False)
    again = await put(private_client, [item(GTIN, a, 2)], complete=False)
    assert staged.json() == again.json()
    committed = await put(private_client, [item(OTHER_GTIN, a, 3)], page=1)
    assert committed.json()["status"] == "committed"
    replay = await put(private_client, [item(OTHER_GTIN, a, 3)], page=1)
    assert (replay.status_code, replay.json()["status"]) == (200, "duplicate")
    early = await put(private_client, [item(GTIN, a, 2)], complete=False)
    assert early.json()["status"] == "duplicate"
    assert len(await stored(candidates)) == 2


async def test_a_lower_generation_is_rejected_and_a_newer_one_discards_an_unfinished_older(
    private_client: AsyncClient, seed: Seed, candidates: Candidates, engine: AsyncEngine
) -> None:
    a = await seed.product("p-a", "Testamol")
    await put(private_client, [item(GTIN, a, 2)], generation=5)
    stale = await put(private_client, [item(GTIN, a, 9)], generation=4)
    assert stale.status_code == 409
    assert stale.json()["error"]["code"] == "generation_stale"
    await put(private_client, [item(OTHER_GTIN, a, 2)], generation=6, page=0, complete=False)
    await put(private_client, [item(GTIN, a, 3)], generation=7, page=0)  # supersedes 6
    assert await stored(candidates) == [("ru", GTIN, a, 3)]
    async with engine.connect() as conn:
        left = (
            await conn.execute(text("SELECT count(*) FROM catalog.gtin_candidate_staging"))
        ).scalar_one()
    assert left == 0


# --- what is dropped --------------------------------------------------------------------------


async def test_unknown_withdrawn_and_restricted_items_are_dropped_and_counted(
    private_client: AsyncClient, seed: Seed, candidates: Candidates
) -> None:
    live = await seed.product("p-a", "Testamol")
    gone = await seed.product("p-gone", "Gonamol", withdrawn=True)
    answer = await put(
        private_client,
        [
            item(GTIN, live, 3),
            item(OTHER_GTIN, gone, 3),  # withdrawn product
            item(gtin14("0460701234569"), uuid.uuid4(), 3),  # unknown product
            item(RESTRICTED, live, 3),  # restricted number
            item("04600000000016", live, 3),  # bad check digit
        ],
    )
    assert answer.status_code == 200
    assert answer.json() == {"status": "committed", "dropped": 4}
    assert await stored(candidates) == [("ru", GTIN, live, 3)]


async def test_the_same_pair_twice_in_a_page_keeps_the_last_count(
    private_client: AsyncClient, seed: Seed, candidates: Candidates
) -> None:
    a = await seed.product("p-a", "Testamol")
    await put(private_client, [item(GTIN, a, 2), item(GTIN, a, 4)])
    assert await stored(candidates) == [("ru", GTIN, a, 4)]


# --- decisions follow the swap ----------------------------------------------------------------


async def test_a_committed_snapshot_promotes_disputes_and_the_lookup_reflects_both(
    client: AsyncClient, private_client: AsyncClient, seed: Seed
) -> None:
    a = await seed.product("p-a", "Testamol")
    b = await seed.product("p-b", "Otheramol")
    await put(
        private_client,
        [item(GTIN, a, 3), item(OTHER_GTIN, a, 3), item(OTHER_GTIN, b, 2)],
    )
    promoted = (await client.post("/v1/gtins/lookup", json={"gtin": GTIN})).json()
    assert promoted["status"] == "found"
    assert promoted["product"]["id"] == str(a)
    disputed = (await client.post("/v1/gtins/lookup", json={"gtin": OTHER_GTIN})).json()
    assert disputed["status"] == "disputed"
    assert disputed["product"] is None


async def test_a_promotion_survives_a_snapshot_without_it_but_a_pending_one_vanishes(
    client: AsyncClient, private_client: AsyncClient, seed: Seed, engine: AsyncEngine
) -> None:
    a = await seed.product("p-a", "Testamol")
    await put(private_client, [item(GTIN, a, 3), item(OTHER_GTIN, a, 2)], generation=1)
    await put(private_client, [], generation=2)  # everyone opted out or erased
    assert (await client.post("/v1/gtins/lookup", json={"gtin": GTIN})).json()["status"] == "found"
    async with engine.connect() as conn:
        statuses = dict(
            (await conn.execute(text("SELECT gtin, status FROM catalog.gtin_link_decisions"))).all()
        )
    assert statuses == {GTIN: "promoted", OTHER_GTIN: "pending"}


async def test_the_ingest_log_line_carries_no_gtin_or_product(
    private_client: AsyncClient, seed: Seed, capfd: Any
) -> None:
    a = await seed.product("p-a", "Testamol")
    await put(private_client, [item(GTIN, a, 3)])
    out = capfd.readouterr()
    assert GTIN not in out.out + out.err
    assert str(a) not in out.out + out.err
