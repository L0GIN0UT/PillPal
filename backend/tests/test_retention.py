"""``cleanup_retention``: invite accepters are forgotten, old invites deleted (ADR 0009 §6)."""

from __future__ import annotations

import uuid
from datetime import timedelta

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.grace_helpers import count, in_days, run_retention
from tests.helpers import accept_invite, create_invite, register, token_of


async def test_the_accepter_is_forgotten_after_the_replay_window(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    invite = await create_invite(client, owner)
    assert (await accept_invite(client, relative, token_of(invite))).status_code == 201
    still_set = "consumed_by_user_id = :u"

    inside = await run_retention(client, in_days(0) + timedelta(hours=23))
    assert inside.invite_accepters_forgotten == 0
    assert await count(engine, "invites", still_set, u=uuid.UUID(relative.id)) == 1

    after = await run_retention(client, in_days(0) + timedelta(hours=25))
    assert after.invite_accepters_forgotten == 1
    assert await count(engine, "invites", still_set, u=uuid.UUID(relative.id)) == 0
    assert await count(engine, "invites", "consumed_at IS NOT NULL") == 1  # the invite stays
    # A replay after the window cannot prove it was the accepter: ``invite_used``.
    replay = await accept_invite(client, relative, token_of(invite))
    assert replay.json()["error"]["code"] == "invite_used"


async def test_invites_are_deleted_thirty_days_after_their_end_of_life(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    consumed = await create_invite(client, owner)
    await accept_invite(client, relative, token_of(consumed))
    revoked = await create_invite(client, owner)
    await client.delete(
        f"/v1/profiles/{owner.self_profile_id}/invites/{revoked['id']}", headers=owner.headers
    )
    expiring = await create_invite(client, owner)  # a 7-day invite: ends at +7 days
    open_invite = await create_invite(client, owner)
    assert await count(engine, "invites") == 4

    assert (await run_retention(client, in_days(29))).invites_deleted == 0
    # Consumed and revoked ended ~now: gone at +30 days; the others ended at +7 days.
    assert (await run_retention(client, in_days(31))).invites_deleted == 2
    assert await count(engine, "invites") == 2
    assert await count(engine, "invites", "id = :i", i=uuid.UUID(expiring["id"])) == 1
    assert (await run_retention(client, in_days(38))).invites_deleted == 2
    assert await count(engine, "invites") == 0
    assert open_invite["id"]
    assert (await run_retention(client, in_days(38))).invites_deleted == 0  # idempotent


async def test_open_invites_are_never_deleted_while_valid(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner = await register(client)
    await create_invite(client, owner)
    report = await run_retention(client, in_days(6))
    assert (report.invites_deleted, report.archives_purged) == (0, 0)
    assert await count(engine, "invites") == 1
