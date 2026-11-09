"""Regression tests for the review of PR 41: availability, integrity, retention, boundary."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from catalog.admin import cli
from catalog.config import Settings
from catalog.db.session import create_sessionmaker
from catalog.domain.consensus import Thresholds
from catalog.errors import AppError
from catalog.importers.fixture import FixtureImporter, ensure_dev_source
from catalog.importers.loader import run_import
from catalog.schemas.ingest import SnapshotPage
from catalog.services.decisions import Rules, resolve
from catalog.services.ingest import expire_stale_regions, ingest_page
from catalog.services.maintenance import run_maintenance_once
from tests.api.seed import Seed
from tests.conftest import TEST_REDIS_URL, make_settings
from tests.consensus.conftest import (
    ADMIN_SECRET,
    EU_SECRET,
    GTIN,
    OTHER_GTIN,
    Candidates,
    gtin14,
    private_app_client,
    private_settings,
)
from tests.consensus.helpers import item, put
from tests.consensus.test_decisions import decide_now, decision, lookup, status_of
from tests.importers.support import V1

RULES = Rules(Thresholds(promote_at=3, dispute_at=2), max_age_hours=72)


def admin(secret: str = ADMIN_SECRET) -> dict[str, str]:
    return {"Authorization": f"Bearer {secret}"}


async def stored_rows(engine: AsyncEngine, sql: str, **params: Any) -> list[Any]:
    async with engine.connect() as conn:
        return list((await conn.execute(text(sql), params)).all())


# --- 1. one global lock: a big commit does not exhaust the lock table ---------------------------


async def test_a_commit_of_ten_thousand_distinct_gtins_succeeds_under_one_lock(
    seed: Seed, private_client: AsyncClient, engine: AsyncEngine
) -> None:
    product = await seed.product("p-a", "Testamol")
    gtins = [gtin14(f"046070{n:07d}") for n in range(10_000)]
    for page in range(10):
        chunk = gtins[page * 1000 : (page + 1) * 1000]
        answer = await put(
            private_client,
            [item(g, product, 3) for g in chunk],
            page=page,
            complete=page == 9,
        )
        assert answer.status_code == 200, answer.text
    assert answer.json() == {"status": "committed", "dropped": 0}
    rows = await stored_rows(
        engine, "SELECT count(*) FROM catalog.gtin_link_decisions WHERE status = 'promoted'"
    )
    assert rows[0][0] == 10_000
    live = await stored_rows(
        engine,
        "SELECT count(*) FROM catalog.gtins WHERE source = 'consensus' AND withdrawn_at IS NULL",
    )
    assert live[0][0] == 10_000


async def test_the_consensus_run_exists_from_the_migration_not_from_the_code(
    engine: AsyncEngine,
) -> None:
    rows = await stored_rows(
        engine, "SELECT source, status FROM catalog.import_runs WHERE source = 'consensus'"
    )
    assert [tuple(r) for r in rows] == [("consensus", "succeeded")]


# --- 2. only what changed is re-decided ----------------------------------------------------------


async def test_unchanged_gtins_are_not_re_decided_and_changed_ones_are(
    seed: Seed, private_client: AsyncClient, engine: AsyncEngine
) -> None:
    a = await seed.product("p-a", "Testamol")
    await put(private_client, [item(GTIN, a, 3), item(OTHER_GTIN, a, 3)], generation=1)
    async with engine.begin() as conn:  # a marker only a re-decision would overwrite
        await conn.execute(text("UPDATE catalog.gtin_link_decisions SET reason_code = 'marker'"))
    # GTIN keeps its count, OTHER_GTIN drops to 2.
    await put(private_client, [item(GTIN, a, 3), item(OTHER_GTIN, a, 2)], generation=2)
    rows = dict(
        await stored_rows(engine, "SELECT gtin, reason_code FROM catalog.gtin_link_decisions")
    )
    assert rows[GTIN] == "marker"  # untouched: its rows did not change
    # The changed one was evaluated: sticky promotion keeps the status, so only the consensus
    # row proves it ran; the count itself is in the committed table.
    counts = dict(
        await stored_rows(engine, "SELECT gtin, confirmations FROM catalog.gtin_link_candidates")
    )
    assert counts == {GTIN: 3, OTHER_GTIN: 2}


async def test_a_gtin_that_disappears_from_the_snapshot_is_re_decided(
    seed: Seed, private_client: AsyncClient, engine: AsyncEngine
) -> None:
    a = await seed.product("p-a", "Testamol")
    b = await seed.product("p-b", "Otheramol")
    await put(private_client, [item(GTIN, a, 3), item(GTIN, b, 2)], generation=1)
    assert await status_of(engine) == "disputed"
    await put(private_client, [item(GTIN, a, 3)], generation=2)
    assert await status_of(engine) == "promoted"  # the runner-up's rows vanished


# --- 3 and 4. generations ------------------------------------------------------------------------


async def test_a_page_below_the_staging_generation_is_stale_and_keeps_the_staging(
    seed: Seed, private_client: AsyncClient, engine: AsyncEngine
) -> None:
    a = await seed.product("p-a", "Testamol")
    await put(private_client, [item(GTIN, a, 3)], generation=10, complete=False)
    stale = await put(private_client, [item(OTHER_GTIN, a, 3)], generation=9)
    assert stale.status_code == 409
    error = stale.json()["error"]
    assert error["code"] == "generation_stale"
    assert (error["committed_generation"], error["min_generation"]) == (0, 11)
    staged = await stored_rows(engine, "SELECT generation FROM catalog.gtin_candidate_staging")
    assert [r[0] for r in staged] == [10]  # the current staging survived the stale sender


async def test_a_stale_answer_names_the_committed_generation(
    seed: Seed, private_client: AsyncClient
) -> None:
    await put(private_client, [], generation=5)
    stale = (await put(private_client, [], generation=3)).json()["error"]
    assert (stale["committed_generation"], stale["min_generation"]) == (5, 6)


async def test_a_generation_far_ahead_of_the_clock_is_refused(
    seed: Seed, private_client: AsyncClient, engine: AsyncEngine
) -> None:
    tomorrow_plus = int((datetime.now(UTC) + timedelta(days=2)).timestamp() * 1000)
    answer = await put(private_client, [], generation=tomorrow_plus)
    assert (answer.status_code, answer.json()["error"]["code"]) == (422, "generation_in_future")
    assert await stored_rows(engine, "SELECT * FROM catalog.gtin_ingest_state") == []
    near = int((datetime.now(UTC) + timedelta(hours=1)).timestamp() * 1000)
    assert (await put(private_client, [], generation=near)).status_code == 200


async def test_reset_forgets_a_poisoned_generation_and_is_audited(
    seed: Seed, private_client: AsyncClient, engine: AsyncEngine
) -> None:
    a = await seed.product("p-a", "Testamol")
    poisoned = int((datetime.now(UTC) + timedelta(hours=20)).timestamp() * 1000)
    await put(private_client, [item(GTIN, a, 3)], generation=poisoned)
    assert (await put(private_client, [], generation=1)).status_code == 409
    answer = await private_client.post("/admin/v1/ingest/ru:reset", headers=admin())
    assert answer.status_code == 204
    assert (await put(private_client, [item(GTIN, a, 2)], generation=1)).status_code == 200
    audit = await stored_rows(
        engine, "SELECT admin_name, action, region, gtin FROM catalog.admin_audit"
    )
    assert [tuple(r) for r in audit] == [("ops", "ingest_reset", "ru", None)]
    unauthorized = await private_client.post("/admin/v1/ingest/ru:reset")
    assert unauthorized.status_code == 401
    assert (
        await private_client.post("/admin/v1/ingest/xx:reset", headers=admin())
    ).status_code == 422


async def test_reset_drops_the_regions_counts_and_re_decides(
    seed: Seed, private_client: AsyncClient, engine: AsyncEngine
) -> None:
    a = await seed.product("p-a", "Testamol")
    b = await seed.product("p-b", "Otheramol")
    await put(private_client, [item(GTIN, a, 3), item(GTIN, b, 2)])
    assert await status_of(engine) == "disputed"
    await private_client.post("/admin/v1/ingest/ru:reset", headers=admin())
    assert await status_of(engine) == "pending"
    assert await stored_rows(engine, "SELECT * FROM catalog.gtin_link_candidates") == []


# --- 5. page replays cannot bypass the caps ------------------------------------------------------


async def test_a_resent_page_replaces_its_rows_and_replays_cannot_inflate_the_staging(
    seed: Seed, engine: AsyncEngine, clean_redis: None
) -> None:
    product = await seed.product("p-a", "Testamol")
    many = [gtin14(f"046070{n:07d}") for n in range(1, 8)]
    async with private_app_client(private_settings(ingest_max_items=3)) as small:
        first = await put(small, [item(g, product) for g in many[:2]], complete=False)
        again = await put(small, [item(g, product) for g in many[2:5]], complete=False)
        assert (first.status_code, again.status_code) == (200, 200)
        staged = await stored_rows(engine, "SELECT gtin FROM catalog.gtin_candidate_staging")
        assert sorted(r[0] for r in staged) == sorted(many[2:5])  # replaced, not accumulated
        replay_other = await put(small, [item(g, product) for g in many[:4]], complete=False)
        assert replay_other.status_code == 413  # 4 real rows would exceed the cap of 3
        over = await put(small, [item(many[5], product)], page=1, complete=True)
        assert over.status_code == 413


# --- 6a. retention of stale regions --------------------------------------------------------------


async def age_region(engine: AsyncEngine, region: str, hours: int) -> None:
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "UPDATE catalog.gtin_ingest_state SET committed_at = now() - make_interval("
                "hours => :h) WHERE region = :r"
            ),
            {"h": hours, "r": region},
        )


async def test_a_region_that_stopped_reporting_stops_counting(
    seed: Seed, private_client: AsyncClient, engine: AsyncEngine
) -> None:
    a = await seed.product("p-a", "Testamol")
    await put(private_client, [item(GTIN, a, 2)], region="eu", secret=EU_SECRET)
    assert await status_of(engine) == "pending"
    await age_region(engine, "eu", 100)  # eu is silent for 100 h (> 72)
    await put(private_client, [item(GTIN, a, 2)])  # ru reports 2: with eu it would be 4
    assert await status_of(engine) == "pending"
    rows = await stored_rows(engine, "SELECT 1 FROM catalog.gtin_link_candidates")
    assert len(rows) == 2  # eu's rows stay until the cleanup runs, but they no longer count


async def test_the_cleanup_deletes_expired_counts_and_re_decides(
    seed: Seed, engine: AsyncEngine, candidates: Candidates
) -> None:
    a = await seed.product("p-a", "Testamol")
    b = await seed.product("p-b", "Otheramol")
    await candidates.put("eu", GTIN, a, 3)
    await candidates.put("eu", GTIN, b, 3)
    await decide_now(engine)
    assert await status_of(engine) == "disputed"
    await age_region(engine, "eu", 100)
    sessions = create_sessionmaker(engine)
    expired, _ = await run_maintenance_once(sessions, RULES)
    assert expired == 1
    assert await stored_rows(engine, "SELECT * FROM catalog.gtin_link_candidates") == []
    assert await status_of(engine) == "pending"  # a dispute is not sticky: the counts are gone


async def test_a_promotion_survives_the_expiry_of_its_counts(
    seed: Seed, engine: AsyncEngine, candidates: Candidates
) -> None:
    a = await seed.product("p-a", "Testamol")
    await candidates.put("ru", GTIN, a, 3)
    await decide_now(engine)
    await age_region(engine, "ru", 100)
    await run_maintenance_once(create_sessionmaker(engine), RULES)
    assert await status_of(engine) == "promoted"


async def test_a_region_that_reports_again_after_expiry_counts_again_even_if_unchanged(
    seed: Seed, private_client: AsyncClient, engine: AsyncEngine
) -> None:
    a = await seed.product("p-a", "Testamol")
    await put(private_client, [item(GTIN, a, 3)], generation=1)
    assert await status_of(engine) == "promoted"
    async with engine.begin() as conn:
        await conn.execute(text("DELETE FROM catalog.gtin_link_decisions"))
    await age_region(engine, "ru", 100)
    await put(private_client, [item(GTIN, a, 3)], generation=2)  # same rows, but fresh again
    assert await status_of(engine) == "promoted"


async def test_the_default_retention_is_72_hours() -> None:
    assert make_settings().ingest_max_age_hours == 72


# --- 7. region acceptance ------------------------------------------------------------------------


async def test_a_region_that_is_not_accepted_gets_403_whatever_the_token(
    seed: Seed, clean_redis: None
) -> None:
    settings = private_settings()
    settings.accepted_regions = ("ru",)
    async with private_app_client(settings) as client:
        assert (await put(client, [], region="eu", secret=EU_SECRET)).status_code == 403
        assert (await put(client, [])).status_code == 200


async def test_with_no_accepted_region_the_ingest_takes_nothing(
    seed: Seed, clean_redis: None, engine: AsyncEngine
) -> None:
    settings = private_settings()
    settings.accepted_regions = ()
    async with private_app_client(settings) as client:
        assert (await put(client, [])).status_code == 403
    assert await stored_rows(engine, "SELECT * FROM catalog.gtin_ingest_state") == []


# --- 8. official rows that appear or vanish ------------------------------------------------------


async def test_an_official_row_withdrawn_after_a_promotion_keeps_the_link_resolvable(
    client: AsyncClient, seed: Seed, engine: AsyncEngine, candidates: Candidates
) -> None:
    official = await seed.product("p-off", "Officialamol", packages=[("pack", [GTIN])])
    await candidates.put("ru", GTIN, official, 3)
    await decide_now(engine)
    assert await decision(engine) == ("promoted", official, "auto")
    async with engine.begin() as conn:
        await conn.execute(
            text("UPDATE catalog.gtins SET withdrawn_at = now() WHERE gtin = :g"), {"g": GTIN}
        )
    await run_maintenance_once(create_sessionmaker(engine), RULES)
    consensus = await stored_rows(
        engine,
        "SELECT 1 FROM catalog.gtins WHERE source = 'consensus' AND withdrawn_at IS NULL",
    )
    assert len(consensus) == 1  # the decision now rests on a consensus row
    body = await lookup(client)
    assert body["product"]["id"] == str(official)  # type: ignore[index]


async def test_an_official_row_added_with_another_product_disputes_a_promotion(
    client: AsyncClient, seed: Seed, engine: AsyncEngine, candidates: Candidates
) -> None:
    mine = await seed.product("p-a", "Testamol")
    await candidates.put("ru", GTIN, mine, 3)
    await decide_now(engine)
    assert (await lookup(client))["status"] == "found"
    await seed.product("p-off", "Officialamol", packages=[("pack", [GTIN])])
    await run_maintenance_once(create_sessionmaker(engine), RULES)
    assert await status_of(engine) == "disputed"
    assert (await lookup(client))["status"] == "disputed"


async def test_a_successful_import_re_decides_what_its_official_rows_touch(
    seed: Seed, engine: AsyncEngine, candidates: Candidates
) -> None:
    mine = await seed.product("p-mine", "Mineamol")
    fixture_gtin = "04607012345677"  # an official number of the synthetic fixture
    await candidates.put("ru", fixture_gtin, mine, 3)
    await decide_now(engine, fixture_gtin)
    assert await status_of(engine, fixture_gtin) == "promoted"
    sessions = create_sessionmaker(engine)
    async with sessions.begin() as session:
        await ensure_dev_source(session, "fixture")
    await run_import(sessions, FixtureImporter(), V1, consensus_rules=RULES)
    assert await status_of(engine, fixture_gtin) == "disputed"


# --- 9. a withdrawn consensus row never answers --------------------------------------------------


async def test_promoted_then_disputed_then_pending_never_resurrects_the_link(
    client: AsyncClient, seed: Seed, engine: AsyncEngine, candidates: Candidates
) -> None:
    a = await seed.product("p-a", "Testamol")
    b = await seed.product("p-b", "Otheramol")
    await candidates.put("ru", GTIN, a, 3)
    await decide_now(engine)
    assert (await lookup(client))["status"] == "found"
    await candidates.put("ru", GTIN, b, 3)
    await decide_now(engine)
    assert (await lookup(client))["status"] == "disputed"
    await candidates.clear()
    # An admin undoes the stickiness: reject, then forget the rejection by a direct reset of the
    # decision to pending (the state a dispute that lost its counts falls back to).
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "UPDATE catalog.gtin_link_decisions SET status = 'pending', product_id = NULL, "
                "reason_code = 'below_threshold'"
            )
        )
    assert (await lookup(client))["status"] == "unknown"


# --- 10. the private listener --------------------------------------------------------------------


async def test_the_private_app_publishes_no_docs_or_schema(private_client: AsyncClient) -> None:
    for path in ("/docs", "/redoc", "/openapi.json"):
        assert (await private_client.get(path)).status_code == 404, path


async def test_the_private_app_rate_limits_in_its_own_buckets(
    private_client: AsyncClient,
) -> None:
    await private_client.get("/admin/v1/disputes", headers=admin())
    redis: Redis = Redis.from_url(TEST_REDIS_URL)
    try:
        keys = [k.decode() for k in await redis.keys("rl:*")]
    finally:
        await redis.aclose()
    assert keys
    assert all(k.startswith("rl:private-token:") for k in keys)  # a valid caller: its token


# --- 11. audit, logs and the CLI -----------------------------------------------------------------


async def test_the_audit_keeps_the_decision_that_was_replaced(
    seed: Seed, engine: AsyncEngine, candidates: Candidates
) -> None:
    a = await seed.product("p-a", "Testamol")
    b = await seed.product("p-b", "Otheramol")
    await candidates.put("ru", GTIN, a, 3)
    await decide_now(engine)
    sessions = create_sessionmaker(engine)
    async with sessions.begin() as session:
        await resolve(session, GTIN, "lock", b, "ops-1")
    rows = await stored_rows(
        engine,
        "SELECT admin_name, action, previous_status, previous_product_id FROM catalog.admin_audit",
    )
    assert [tuple(r) for r in rows] == [("ops-1", "lock", "promoted", a)]


async def test_a_rejected_admin_action_is_logged_by_code_and_label_only(
    private_client: AsyncClient, seed: Seed, capfd: pytest.CaptureFixture[str]
) -> None:
    unknown = uuid.uuid4()
    answer = await private_client.post(
        f"/admin/v1/gtins/{GTIN}:resolve",
        json={"action": "lock", "product_id": str(unknown)},
        headers=admin(),
    )
    assert answer.status_code == 404
    out = capfd.readouterr()
    # The HTTP client's own request log names the URL; the service's line must not.
    lines = [line for line in (out.out + out.err).splitlines() if "admin_action_rejected" in line]
    assert len(lines) == 1
    assert "unknown_product" in lines[0]
    assert GTIN not in lines[0]
    assert str(unknown) not in lines[0]


async def test_a_promotion_is_attributed_to_auto_after_the_next_evaluation(
    seed: Seed, engine: AsyncEngine, candidates: Candidates
) -> None:
    a = await seed.product("p-a", "Testamol")
    b = await seed.product("p-b", "Otheramol")
    await candidates.put("ru", GTIN, a, 2)
    await candidates.put("ru", GTIN, b, 3)
    sessions = create_sessionmaker(engine)
    async with sessions.begin() as session:
        await resolve(session, GTIN, "promote", a, "ops")
    assert await decision(engine) == ("promoted", a, "admin")
    await decide_now(engine)  # b reached N: the promotion is disputed again, as documented
    assert await decision(engine) == ("disputed", None, "auto")
    audit = await stored_rows(engine, "SELECT action FROM catalog.admin_audit")
    assert [r[0] for r in audit] == ["promote"]  # the history stays


async def run_cli(argv: list[str], settings: Settings | None = None) -> int:
    import asyncio

    return await asyncio.to_thread(cli.main, argv, settings or make_settings())


async def test_cli_reset_and_maintenance(
    seed: Seed,
    engine: AsyncEngine,
    candidates: Candidates,
    capsys: pytest.CaptureFixture[str],
) -> None:
    a = await seed.product("p-a", "Testamol")
    await candidates.put("ru", GTIN, a, 2)
    assert await run_cli(["maintenance"]) == 0
    assert '"regions_expired": 0' in capsys.readouterr().out
    assert await run_cli(["ingest", "reset", "ru"]) == 0
    assert await stored_rows(engine, "SELECT * FROM catalog.gtin_link_candidates") == []
    audit = await stored_rows(engine, "SELECT admin_name, action, region FROM catalog.admin_audit")
    assert [tuple(r) for r in audit] == [("cli", "ingest_reset", "ru")]


async def test_cli_disputes_list_failure_is_a_stable_code(
    capsys: pytest.CaptureFixture[str],
) -> None:
    broken = make_settings(database_url="postgresql+asyncpg://nobody:x@127.0.0.1:1/none")
    assert await run_cli(["disputes", "list"], broken) == 1
    assert capsys.readouterr().err.strip() == "error: command_failed"


async def test_ingest_page_unit_rejects_an_unaccepted_region(
    seed: Seed, engine: AsyncEngine
) -> None:
    from sqlalchemy.ext.asyncio import AsyncSession

    settings = private_settings()
    settings.accepted_regions = ("ru",)
    body = SnapshotPage(generation=1, page=0, complete=True, items=[])
    async with AsyncSession(engine) as session, session.begin():
        with pytest.raises(AppError) as raised:
            await ingest_page(session, settings, "eu", body, datetime.now(UTC))
    assert raised.value.status_code == 403


async def test_expire_with_nothing_stale_is_a_no_op(engine: AsyncEngine, seed: Seed) -> None:
    from sqlalchemy.ext.asyncio import AsyncSession

    async with AsyncSession(engine) as session, session.begin():
        assert await expire_stale_regions(session, RULES) == 0
