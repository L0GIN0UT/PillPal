"""Follow-ups of the second review: token rate limits, staging expiry, maintenance upkeep."""

from __future__ import annotations

from redis.asyncio import Redis
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession

from catalog.db.session import create_sessionmaker
from catalog.domain.consensus import Thresholds
from catalog.services.decisions import Rules
from catalog.services.ingest import expire_stale_regions
from catalog.services.maintenance import claim_maintenance, purge_audit, run_maintenance_once
from tests.api.seed import Seed
from tests.conftest import TEST_REDIS_URL
from tests.consensus.conftest import (
    ADMIN_SECRET,
    GTIN,
    RU_NEXT_SECRET,
    private_app_client,
    private_settings,
)
from tests.consensus.helpers import item, put

RULES = Rules(Thresholds(promote_at=3, dispute_at=2), max_age_hours=72)


async def rows(engine: AsyncEngine, sql: str, **params: object) -> list[object]:
    async with engine.connect() as conn:
        return list((await conn.execute(text(sql), params)).all())


# --- authenticated ingest is limited per token, failures per IP ---


async def test_authenticated_ingest_is_not_throttled_by_the_low_ip_limit(
    seed: Seed, clean_redis: None
) -> None:
    settings = private_settings(private_rate_limit_ip_max=3)
    async with private_app_client(settings) as client:
        codes = [(await put(client, [], generation=n)).status_code for n in range(1, 11)]
    assert codes == [200] * 10


async def test_each_token_has_its_own_bucket_and_a_429_carries_retry_after(
    seed: Seed, clean_redis: None
) -> None:
    settings = private_settings(private_rate_limit_token_max=3)
    async with private_app_client(settings) as client:
        codes = [(await put(client, [], generation=n)).status_code for n in range(1, 5)]
        assert codes == [200, 200, 200, 429]
        limited = await put(client, [], generation=9)
        assert int(limited.headers["retry-after"]) >= 1
        assert (await put(client, [], generation=100, secret=RU_NEXT_SECRET)).status_code == 200


async def test_failed_authentication_is_limited_per_ip_and_valid_calls_are_not_counted_there(
    seed: Seed, clean_redis: None
) -> None:
    settings = private_settings(private_rate_limit_ip_max=2)
    async with private_app_client(settings) as client:
        bad = {"Authorization": "Bearer nope"}
        codes = [
            (await client.get("/admin/v1/disputes", headers=bad)).status_code for _ in range(3)
        ]
        assert codes == [401, 401, 429]
        # the valid admin token is unaffected by the failures of this address
        ok = await client.get(
            "/admin/v1/disputes", headers={"Authorization": f"Bearer {ADMIN_SECRET}"}
        )
        assert ok.status_code == 200
    redis: Redis = Redis.from_url(TEST_REDIS_URL)
    try:
        keys = sorted(k.decode().split(":")[1] for k in await redis.keys("rl:*"))
    finally:
        await redis.aclose()
    assert set(keys) == {"private-ip", "private-token"}


# --- expiry also discards unfinished staging ---


async def test_a_region_with_staging_but_no_commit_is_stale_and_its_staging_is_discarded(
    seed: Seed, private_client: object, engine: AsyncEngine
) -> None:
    product = await seed.product("p-a", "Testamol")
    async with private_app_client(private_settings()) as client:
        await put(client, [item(GTIN, product, 3)], complete=False)
    assert await rows(engine, "SELECT 1 FROM catalog.gtin_candidate_staging")
    async with AsyncSession(engine) as session, session.begin():
        assert await expire_stale_regions(session, RULES) == 1
    assert await rows(engine, "SELECT 1 FROM catalog.gtin_candidate_staging") == []
    state = await rows(
        engine, "SELECT staging_generation, staged_pages FROM catalog.gtin_ingest_state"
    )
    assert [tuple(r) for r in state] == [(None, [])]  # type: ignore[arg-type]


async def test_a_fresh_region_keeps_its_unfinished_staging(
    seed: Seed, engine: AsyncEngine, clean_redis: None
) -> None:
    product = await seed.product("p-a", "Testamol")
    async with private_app_client(private_settings()) as client:
        await put(client, [item(GTIN, product, 3)], generation=1)
        await put(client, [item(GTIN, product, 3)], generation=2, complete=False)
    async with AsyncSession(engine) as session, session.begin():
        assert await expire_stale_regions(session, RULES) == 0
    assert await rows(engine, "SELECT 1 FROM catalog.gtin_candidate_staging")


# --- one maintenance run per interval, audit retention ---


async def test_only_one_process_claims_the_maintenance_per_interval(clean_redis: None) -> None:
    redis: Redis = Redis.from_url(TEST_REDIS_URL)
    try:
        assert await claim_maintenance(redis, 3600) is True
        assert await claim_maintenance(redis, 3600) is False  # another worker, same window
        ttl = await redis.ttl("catalog_maintenance")
        assert 0 < ttl <= 3600
    finally:
        await redis.aclose()


async def test_an_unreachable_redis_does_not_stop_the_maintenance() -> None:
    dead: Redis = Redis.from_url("redis://127.0.0.1:1/0", socket_connect_timeout=0.2)
    try:
        assert await claim_maintenance(dead, 3600) is True  # fail open; the DB work is idempotent
    finally:
        await dead.aclose()


async def test_old_audit_rows_are_purged_by_the_maintenance(
    seed: Seed, engine: AsyncEngine
) -> None:
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "INSERT INTO catalog.admin_audit (admin_name, action, gtin, at) VALUES "
                "('ops', 'reject', :g, now() - interval '800 days'), "
                "('ops', 'reject', :g, now() - interval '10 days')"
            ),
            {"g": GTIN},
        )
    sessions = create_sessionmaker(engine)
    async with sessions.begin() as session:
        assert await purge_audit(session, 730) == 1
    left = await rows(engine, "SELECT count(*) FROM catalog.admin_audit")
    assert left[0][0] == 1  # type: ignore[index]
    await run_maintenance_once(sessions, Rules(RULES.thresholds, 72, audit_retention_days=5))
    assert (await rows(engine, "SELECT count(*) FROM catalog.admin_audit"))[0][0] == 0  # type: ignore[index]
