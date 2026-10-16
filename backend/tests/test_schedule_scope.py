"""Schedule writes journal into the medication's own profile, whatever the caller knows."""

from __future__ import annotations

import uuid

from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession

from app.services import entities as svc
from app.services.changes import lock_journal
from app.services.rules import canonical_rule
from tests.helpers import create_managed_profile, daily_rule, register
from tests.sync_helpers import make_medication


async def test_schedule_services_journal_into_the_profile_of_their_medication(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    ward = await create_managed_profile(client, user)
    medication = await make_medication(client, user, ward)
    schedule_id = uuid.uuid4()
    async with AsyncSession(engine) as session:
        await lock_journal(session, [uuid.UUID(user.id)])
        ctx = svc.WriteContext.server(uuid.UUID(user.id), "dev-1")
        row = await svc.create_schedule(
            session,
            ctx,
            schedule_id=schedule_id,
            medication_id=uuid.UUID(medication),
            rule=canonical_rule(daily_rule(("09:00",))),
        )
        row = await svc.update_schedule(
            session, ctx.for_row(row.client_updated_at), row, canonical_rule(daily_rule(("10:00",)))
        )
        await svc.delete_schedule(session, ctx.for_row(row.client_updated_at), row)
        await session.commit()
    async with engine.connect() as conn:
        scopes = {
            str(r[0])
            for r in await conn.execute(
                text("SELECT profile_id FROM sync_changes WHERE entity_id = :i"),
                {"i": schedule_id},
            )
        }
    assert scopes == {ward}
