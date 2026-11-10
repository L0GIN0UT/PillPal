"""Revision 0020 (promo codes): round trip, CHECKs, keys and the widened audit actions."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Any

import pytest
from sqlalchemy import text
from sqlalchemy.exc import DBAPIError, IntegrityError
from sqlalchemy.ext.asyncio import AsyncEngine, create_async_engine

from tests.helpers import downgrade, run_migrations
from tests.test_config_and_migrations import _recreate_db
from tests.test_entitlement_migrations import _audit, _entitlement, _user, predecessor
from tests.test_relatives_migrations import _objects

DB = "pillpal_test_promo_migrations"
REVISION = "0020_promo_codes"
DIGEST = "a" * 64
NOW = datetime(2026, 11, 10, 12, 0, tzinfo=UTC)


def test_the_revision_follows_the_audit_table() -> None:
    assert predecessor(REVISION) == "0019_admin_audit"


async def test_the_revision_upgrades_and_downgrades_cleanly() -> None:
    before = predecessor(REVISION)
    url = await _recreate_db(DB)
    run_migrations(url, before)
    engine = create_async_engine(url)
    try:
        baseline = await _objects(engine)
        run_migrations(url, REVISION)
        assert await _objects(engine) != baseline
        downgrade(url, before)
        assert await _objects(engine) == baseline  # tables, indexes and the old CHECK
        run_migrations(url, REVISION)
    finally:
        await engine.dispose()


async def test_the_downgrade_removes_promo_audit_rows_and_restores_the_narrow_check() -> None:
    before = predecessor(REVISION)
    url = await _recreate_db(DB)
    run_migrations(url, REVISION)
    engine = create_async_engine(url)
    try:
        async with engine.begin() as conn:
            await _audit(conn, action="entitlement_grant")
            await _audit(conn, action="promo_create")
            await _audit(conn, action="promo_disable")
        downgrade(url, before)
        async with engine.begin() as conn:
            left = (await conn.execute(text("SELECT action FROM admin_audit"))).scalars().all()
        assert left == ["entitlement_grant"]
        async with engine.connect() as conn:
            with pytest.raises(DBAPIError, match="ck_admin_audit_action"):
                await _audit(conn, action="promo_create")
            await conn.rollback()
    finally:
        await engine.dispose()


async def test_the_audit_accepts_the_promo_actions_without_a_target(engine: AsyncEngine) -> None:
    async with engine.begin() as conn:
        await _audit(conn, action="promo_create")
        await _audit(conn, action="promo_disable")
        count = (await conn.execute(text("SELECT count(*) FROM admin_audit"))).scalar_one()
        assert count == 2


@pytest.mark.parametrize("action", ["promo_delete", "promo", "entitlement_grant "])
async def test_the_audit_still_refuses_other_actions(engine: AsyncEngine, action: str) -> None:
    async with engine.connect() as conn:
        with pytest.raises(DBAPIError, match="ck_admin_audit_action"):
            await _audit(conn, action=action)
        await conn.rollback()


async def _code(conn: Any, **values: Any) -> uuid.UUID:
    params = {
        "id": uuid.uuid4(),
        "digest": uuid.uuid4().hex * 2,
        "label": "synthetic-campaign",
        "kind": "ads_removed",
        "days": None,
        "max": 1,
        "act": 0,
    } | values
    await conn.execute(
        text(
            "INSERT INTO promo_codes (id, code_digest, label, kind, grant_days, max_activations, "
            "activations) VALUES (:id, :digest, :label, :kind, :days, :max, :act)"
        ),
        params,
    )
    return uuid.UUID(str(params["id"]))


@pytest.mark.parametrize(
    ("values", "constraint"),
    [
        ({"digest": "ABC"}, "code_digest"),
        ({"digest": "A" * 64}, "code_digest"),  # upper case is not the stored form
        ({"digest": "a" * 63}, "code_digest"),
        ({"digest": "a" * 65}, "code_digest"),
        ({"label": ""}, "label"),
        ({"label": "l" * 65}, "label"),
        ({"kind": "gold"}, "kind"),
        ({"days": 0}, "grant_days"),
        ({"days": 3651}, "grant_days"),
        ({"max": 0}, "max_activations"),
        ({"act": -1}, "activations"),
        ({"max": 2, "act": 3}, "activations"),
    ],
)
async def test_code_checks_are_enforced(
    engine: AsyncEngine, values: dict[str, Any], constraint: str
) -> None:
    async with engine.connect() as conn:
        with pytest.raises(DBAPIError, match=f"ck_promo_codes_{constraint}"):
            await _code(conn, **values)
        await conn.rollback()


async def test_code_boundaries_are_accepted(engine: AsyncEngine) -> None:
    async with engine.begin() as conn:
        await _code(conn, digest="0" * 64, label="l", days=1, max=1, act=1)
        await _code(conn, digest="f" * 64, label="l" * 64, days=3650, max=5, act=5)
        await _code(conn, kind="limits_lifted", days=None)
        count = (await conn.execute(text("SELECT count(*) FROM promo_codes"))).scalar_one()
        assert count == 3


async def test_the_digest_is_unique(engine: AsyncEngine) -> None:
    async with engine.connect() as conn:
        await _code(conn, digest=DIGEST)
        with pytest.raises(IntegrityError, match="uq_promo_codes_code_digest"):
            await _code(conn, digest=DIGEST)
        await conn.rollback()


async def _redemption(conn: Any, code_id: uuid.UUID, user_id: uuid.UUID, entitlement: Any) -> None:
    await conn.execute(
        text(
            "INSERT INTO promo_redemptions (code_id, user_id, redeemed_at, entitlement_id) "
            "VALUES (:c, :u, :t, :e)"
        ),
        {"c": code_id, "u": user_id, "t": NOW, "e": entitlement},
    )


async def test_a_redemption_is_one_per_account_and_code(engine: AsyncEngine) -> None:
    async with engine.connect() as conn:
        user_id, code_id = await _user(conn), await _code(conn, max=5)
        entitlement = uuid.uuid4()
        await _entitlement(conn, user_id, id=entitlement)
        await _redemption(conn, code_id, user_id, entitlement)
        with pytest.raises(IntegrityError, match="pk_promo_redemptions"):
            await _redemption(conn, code_id, user_id, entitlement)
        await conn.rollback()


async def test_the_entitlement_may_follow_the_redemption_in_one_transaction(
    engine: AsyncEngine,
) -> None:
    async with engine.begin() as conn:
        user_id, code_id = await _user(conn), await _code(conn)
        entitlement = uuid.uuid4()
        await _redemption(conn, code_id, user_id, entitlement)  # the foreign key waits
        await _entitlement(conn, user_id, id=entitlement)
    async with engine.connect() as conn:
        count = (await conn.execute(text("SELECT count(*) FROM promo_redemptions"))).scalar_one()
        assert count == 1


async def test_a_redemption_without_its_entitlement_cannot_commit(engine: AsyncEngine) -> None:
    async with engine.connect() as conn:
        user_id, code_id = await _user(conn), await _code(conn)
        await _redemption(conn, code_id, user_id, uuid.uuid4())
        with pytest.raises(IntegrityError, match="fk_promo_redemptions_entitlement_id"):
            await conn.commit()
        await conn.rollback()


async def test_a_redemption_needs_an_existing_code_and_account(engine: AsyncEngine) -> None:
    async with engine.connect() as conn:
        user_id = await _user(conn)
        entitlement = uuid.uuid4()
        await _entitlement(conn, user_id, id=entitlement)
        with pytest.raises(IntegrityError, match="fk_promo_redemptions_code_id"):
            await _redemption(conn, uuid.uuid4(), user_id, entitlement)
        await conn.rollback()


async def test_redemptions_cascade_with_the_user_and_the_code_stays(engine: AsyncEngine) -> None:
    async with engine.begin() as conn:
        user_id, code_id = await _user(conn), await _code(conn)
        entitlement = uuid.uuid4()
        await _entitlement(conn, user_id, id=entitlement)
        await _redemption(conn, code_id, user_id, entitlement)
        await conn.execute(text("DELETE FROM users WHERE id = :u"), {"u": user_id})
        redemptions = (
            await conn.execute(text("SELECT count(*) FROM promo_redemptions"))
        ).scalar_one()
        codes = (await conn.execute(text("SELECT count(*) FROM promo_codes"))).scalar_one()
        assert (redemptions, codes) == (0, 1)
