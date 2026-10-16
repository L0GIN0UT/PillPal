"""Widening a medication re-journals all its dose events in one statement (ADR 0006 §4)."""

from __future__ import annotations

import uuid
from collections.abc import Iterator
from contextlib import contextmanager
from typing import Any

from httpx import AsyncClient
from sqlalchemy import event, text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.helpers import link_accounts, register
from tests.sync_helpers import make_medication, set_privacy, sync_all

EVENTS = 5000  # a medication taken five times a day for about three years


@contextmanager
def count_inserts_into_the_journal(engine: AsyncEngine) -> Iterator[list[str]]:
    seen: list[str] = []

    def record(conn: Any, cursor: Any, statement: str, *args: Any) -> None:
        if statement.lstrip().upper().startswith("INSERT INTO SYNC_CHANGES"):
            seen.append(statement)

    event.listen(engine.sync_engine, "before_cursor_execute", record)
    try:
        yield seen
    finally:
        event.remove(engine.sync_engine, "before_cursor_execute", record)


async def test_widening_a_medication_with_thousands_of_events_is_one_insert(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, viewer = await register(client), await register(client)
    await link_accounts(client, owner, viewer, "viewer")
    pid = owner.self_profile_id
    medication = await make_medication(client, owner, pid, "hidden")
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "INSERT INTO dose_events (id, profile_id, medication_id, type, at) "
                "SELECT gen_random_uuid(), :p, :m, 'taken', now() - make_interval(mins => n) "
                "FROM generate_series(1, :n) AS n"
            ),
            {"p": pid, "m": medication, "n": EVENTS},
        )
    with count_inserts_into_the_journal(engine) as inserts:
        await set_privacy(client, owner, medication, "shared")
    # The medication's privacy row, its (no) schedules, and every event: three statements at most.
    assert len(inserts) <= 3
    synced = await sync_all(client, viewer, {pid: 0}, limit=500)
    assert len(synced.of("dose_event")) == EVENTS
    assert synced.pages >= EVENTS // 500


async def test_narrowing_does_not_rejournal_events(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner = await register(client)
    medication = await make_medication(client, owner, owner.self_profile_id)
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "INSERT INTO dose_events (id, profile_id, medication_id, type, at) "
                "VALUES (:i, :p, :m, 'taken', now())"
            ),
            {"i": str(uuid.uuid4()), "p": owner.self_profile_id, "m": medication},
        )
    with count_inserts_into_the_journal(engine) as inserts:
        await set_privacy(client, owner, medication, "hidden")
    assert len(inserts) <= 2  # the privacy row and the schedules (none): no events
