"""Revisions 0012 (missed_dose_alerts, detector_state) and 0013 (dose-event indexes)."""

from __future__ import annotations

import uuid
from typing import Any

import pytest
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine, create_async_engine

from tests.helpers import downgrade, run_migrations
from tests.test_config_and_migrations import _recreate_db, _tables

DB = "pillpal_test_detector_migrations"
ALERTS = "0012_missed_dose_alerts"
INDEXES = "0013_dose_events_detector_idx"
BEFORE = "0011_push_outbox"


def test_revision_ids_fit_alembic_version_column() -> None:
    assert len(ALERTS) <= 32
    assert len(INDEXES) <= 32


async def _indexes(engine: AsyncEngine) -> set[str]:
    async with engine.connect() as conn:
        rows = await conn.execute(
            text("SELECT indexname FROM pg_indexes WHERE tablename = 'dose_events'")
        )
        return {r[0] for r in rows}


async def test_alerts_revision_round_trips() -> None:
    url = await _recreate_db(DB)
    run_migrations(url, BEFORE)
    engine = create_async_engine(url)
    try:
        assert "missed_dose_alerts" not in await _tables(engine)
        run_migrations(url, ALERTS)
        assert {"missed_dose_alerts", "detector_state"} <= await _tables(engine)
        downgrade(url, BEFORE)
        tables = await _tables(engine)
        assert "missed_dose_alerts" not in tables
        assert "detector_state" not in tables
        run_migrations(url, ALERTS)
        assert "missed_dose_alerts" in await _tables(engine)
    finally:
        await engine.dispose()


async def test_index_revision_round_trips() -> None:
    url = await _recreate_db(DB)
    run_migrations(url, ALERTS)
    engine = create_async_engine(url)
    try:
        wanted = {"ix_dose_events_snooze_until", "ix_dose_events_undo_recorded_at"}
        assert not wanted & await _indexes(engine)
        run_migrations(url, INDEXES)
        assert wanted <= await _indexes(engine)
        downgrade(url, ALERTS)
        assert not wanted & await _indexes(engine)
        run_migrations(url, INDEXES)
        assert wanted <= await _indexes(engine)
    finally:
        await engine.dispose()


@pytest.fixture
async def migrated_engine() -> AsyncEngine:
    url = await _recreate_db(DB)
    run_migrations(url, "head")
    engine = create_async_engine(url)
    yield engine  # type: ignore[misc]
    await engine.dispose()


async def _seed(conn: AsyncConnection) -> tuple[uuid.UUID, uuid.UUID]:
    user_id, profile_id, medication_id = uuid.uuid4(), uuid.uuid4(), uuid.uuid4()
    await conn.execute(
        text("INSERT INTO users (id, email, password_hash, region) VALUES (:u, :e, 'x', 'ru')"),
        {"u": user_id, "e": f"{user_id.hex[:8]}@example.com"},
    )
    await conn.execute(
        text(
            "INSERT INTO profiles (id, owner_user_id, kind, display_name, timezone, "
            "client_updated_at) VALUES (:p, :u, 'self', 'Me', 'UTC', now())"
        ),
        {"p": profile_id, "u": user_id},
    )
    await conn.execute(
        text(
            "INSERT INTO medications (id, profile_id, name, client_updated_at) "
            "VALUES (:m, :p, 'Synthetic', now())"
        ),
        {"m": medication_id, "p": profile_id},
    )
    return profile_id, medication_id


async def _alert(
    conn: AsyncConnection, profile_id: uuid.UUID, medication_id: uuid.UUID, **overrides: Any
) -> None:
    values: dict[str, Any] = {
        "id": uuid.uuid4(),
        "p": profile_id,
        "m": medication_id,
        "key": f"{uuid.uuid4()}/2026-10-17T08:00",
        "variant": "missed",
    }
    values.update(overrides)
    await conn.execute(
        text(
            "INSERT INTO missed_dose_alerts (id, profile_id, medication_id, occurrence_key, "
            "due_at, variant, detected_at) VALUES (:id, :p, :m, :key, now(), :variant, now())"
        ),
        values,
    )


async def test_one_alert_per_profile_and_occurrence(migrated_engine: AsyncEngine) -> None:
    async with migrated_engine.connect() as conn:
        profile_id, medication_id = await _seed(conn)
        await _alert(conn, profile_id, medication_id, key="k/2026-10-17T08:00")
        with pytest.raises(IntegrityError, match="uq_missed_dose_alerts"):
            await _alert(conn, profile_id, medication_id, key="k/2026-10-17T08:00")


@pytest.mark.parametrize(
    ("overrides", "constraint"),
    [
        ({"variant": "late"}, "ck_missed_dose_alerts_variant"),
        ({"key": "k" * 65}, "ck_missed_dose_alerts_occurrence_key"),
    ],
)
async def test_alert_checks(
    migrated_engine: AsyncEngine, overrides: dict[str, Any], constraint: str
) -> None:
    async with migrated_engine.connect() as conn:
        profile_id, medication_id = await _seed(conn)
        with pytest.raises(IntegrityError, match=constraint):
            await _alert(conn, profile_id, medication_id, **overrides)


async def test_alerts_follow_their_profile_and_medication(migrated_engine: AsyncEngine) -> None:
    async with migrated_engine.begin() as conn:
        profile_id, medication_id = await _seed(conn)
        await _alert(conn, profile_id, medication_id)
        await conn.execute(text("DELETE FROM medications WHERE id = :m"), {"m": medication_id})
        remaining = await conn.execute(text("SELECT count(*) FROM missed_dose_alerts"))
        assert remaining.scalar_one() == 0


async def test_detector_state_is_seeded_with_one_watermark(migrated_engine: AsyncEngine) -> None:
    async with migrated_engine.connect() as conn:
        rows = (
            await conn.execute(text("SELECT name, watermark IS NOT NULL FROM detector_state"))
        ).all()
        assert rows == [("missed_dose", True)]
        with pytest.raises(IntegrityError, match="pk_detector_state"):
            await conn.execute(
                text("INSERT INTO detector_state (name, watermark) VALUES ('missed_dose', now())")
            )
