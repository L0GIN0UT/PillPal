"""Helpers of the missed-dose detector suites: a world (owner, profile, medication, schedule,
relatives with push tokens), direct event inserts with chosen instants, and reads of the results.

Everything is synthetic. Occurrences of the default world are 08:00 UTC on 2026-10-17 with the
default grace of 30 minutes, so their alert is due at 08:30 UTC.
"""

from __future__ import annotations

import uuid
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import Any

from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.config import Settings
from app.services.missed_doses import TickReport, detect_missed_doses
from tests.helpers import (
    User,
    create_managed_profile,
    create_medication,
    create_schedule,
    daily_rule,
    link_accounts,
    register,
)
from tests.push_helpers import fcm_token, put_token, rows

DAY = "2026-10-17"
LONG_AGO = datetime(2026, 1, 1, tzinfo=UTC)
FAR_FUTURE = datetime(2030, 1, 1, tzinfo=UTC)
GRACE = timedelta(minutes=30)


def at(hour: int, minute: int = 0, day: int = 17) -> datetime:
    return datetime(2026, 10, day, hour, minute, tzinfo=UTC)


@dataclass
class World:
    owner: User
    profile_id: str
    medication_id: str
    schedule_id: str
    managed: bool
    relatives: dict[str, User] = field(default_factory=dict)

    def key(self, time: str = "08:00", day: str = DAY) -> str:
        return f"{self.schedule_id}/{day}T{time}"


async def make_world(
    client: AsyncClient,
    engine: AsyncEngine,
    *,
    managed: bool = False,
    relatives: tuple[str, ...] = ("viewer",),
    privacy: str = "shared",
    timezone: str = "UTC",
    times: tuple[str, ...] = ("08:00",),
    rule: dict[str, Any] | None = None,
    medication: dict[str, Any] | None = None,
) -> World:
    """An owner with one medication on one schedule and one relative per entry of ``relatives``.

    Relatives register a push token on ``dev-1``. Rows that the tests reason about in the
    past (schedule, grants, owner devices) are backdated: the database stamps them with the real
    clock, the detector runs on a fake one.
    """
    owner = await register(client, timezone=timezone)
    profile_id = (
        await create_managed_profile(client, owner, timezone=timezone)
        if managed
        else owner.self_profile_id
    )
    med = await create_medication(
        client, owner, profile_id=profile_id, privacy=privacy, **(medication or {})
    )
    schedule = await create_schedule(client, owner, med["id"], rule or daily_rule(times))
    world = World(owner, profile_id, med["id"], schedule["id"], managed)
    for index, role in enumerate(relatives):
        relative = await register(client)
        await link_accounts(client, owner, relative, role, profile_id)
        await register_token(client, relative)
        world.relatives[role if role not in world.relatives else f"{role}{index}"] = relative
    async with engine.begin() as conn:
        await conn.execute(text("UPDATE schedules SET created_at = :t"), {"t": LONG_AGO})
        await conn.execute(text("UPDATE profile_grants SET created_at = :t"), {"t": LONG_AGO})
    await set_last_seen(engine, owner, FAR_FUTURE)
    return world


async def register_token(client: AsyncClient, user: User, device: str = "dev-1") -> None:
    """A push token unique to the user and device (a token seen on two accounts is reassigned)."""
    resp = await put_token(client, user, device, token=fcm_token(f"{user.id[:8]}-{device}"))
    assert resp.status_code == 200, resp.text


async def set_last_seen(engine: AsyncEngine, user: User, seen: datetime) -> None:
    """The user's one device (created if missing) was last seen at ``seen``."""
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "INSERT INTO devices (id, user_id, device_id, last_seen_at) "
                "VALUES (gen_random_uuid(), :u, 'owner-dev', :t) "
                "ON CONFLICT (user_id, device_id) DO UPDATE SET last_seen_at = :t"
            ),
            {"u": uuid.UUID(user.id), "t": seen},
        )


async def insert_event(
    engine: AsyncEngine,
    world: World,
    type_: str,
    when: datetime,
    key: str | None,
    *,
    target: uuid.UUID | None = None,
    snooze_until: datetime | None = None,
    recorded_at: datetime | None = None,
    event_id: uuid.UUID | None = None,
) -> uuid.UUID:
    """A dose event written straight into the table, with a chosen ``at`` and ``recorded_at``."""
    event_id = event_id or uuid.uuid4()
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "INSERT INTO dose_events (id, profile_id, medication_id, occurrence_key, type, "
                "target_event_id, at, recorded_at, snooze_until) VALUES (:id, :p, :m, :k, :t, "
                ":target, :at, :rec, :until)"
            ),
            {
                "id": event_id,
                "p": uuid.UUID(world.profile_id),
                "m": uuid.UUID(world.medication_id),
                "k": key,
                "t": type_,
                "target": target,
                "at": when,
                "rec": recorded_at or when,
                "until": snooze_until,
            },
        )
    return event_id


async def set_watermark(engine: AsyncEngine, watermark: datetime) -> None:
    async with engine.begin() as conn:
        await conn.execute(
            text("UPDATE detector_state SET watermark = :w WHERE name = 'missed_dose'"),
            {"w": watermark},
        )


async def watermark(engine: AsyncEngine) -> datetime:
    async with engine.connect() as conn:
        return (  # type: ignore[no-any-return]
            await conn.execute(text("SELECT watermark FROM detector_state"))
        ).scalar_one()


async def tick(
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: datetime,
    *,
    start: datetime | None = None,
    engine: AsyncEngine | None = None,
) -> TickReport:
    """One detector tick at ``now``; ``start`` first moves the watermark there."""
    if start is not None:
        assert engine is not None
        await set_watermark(engine, start)
    return await detect_missed_doses(maker, settings, now)


async def check_window(
    maker: async_sessionmaker[AsyncSession],
    engine: AsyncEngine,
    settings: Settings,
    fires: datetime,
) -> TickReport:
    """A tick whose window ``[fires - 5 min, fires + 5 min)`` contains ``fires``."""
    await set_watermark(engine, fires - timedelta(minutes=5))
    return await detect_missed_doses(maker, settings, fires + timedelta(minutes=5))


async def alert_rows(engine: AsyncEngine) -> list[Any]:
    return await rows(
        engine,
        "SELECT id, profile_id, medication_id, occurrence_key, due_at, variant, detected_at, "
        "resolved_at FROM missed_dose_alerts ORDER BY detected_at, occurrence_key",
    )


async def missed_pushes(engine: AsyncEngine, kind: str = "missed") -> list[Any]:
    return await rows(
        engine,
        "SELECT o.id, o.recipient_user_id, o.payload, o.subject_medication_id, o.status "
        "FROM push_outbox o WHERE o.kind = :k ORDER BY o.id",
        k=kind,
    )


def recipients_of_pushes(pushes: list[Any]) -> list[str]:
    return sorted(str(p.recipient_user_id) for p in pushes)


async def sql(engine: AsyncEngine, statement: str, **params: Any) -> None:
    async with engine.begin() as conn:
        await conn.execute(text(statement), params)


Ticker = Callable[[datetime], Any]
