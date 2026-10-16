"""Database invariants of ``invites`` (ADR 0009): constraints, guard trigger, cascades."""

from __future__ import annotations

import uuid
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine

from tests.helpers import register
from tests.test_grant_triggers import managed_profile, tx


async def invite(
    conn: AsyncConnection, profile_id: str, creator_id: str, **overrides: Any
) -> dict[str, Any]:
    columns: dict[str, Any] = {
        "id": str(uuid.uuid4()),
        "profile_id": profile_id,
        "created_by_user_id": creator_id,
        "role": "viewer",
        "disclosure_version": 1,
        "token_hash": uuid.uuid4().hex + uuid.uuid4().hex,
        "expires_at": text("now() + interval '1 day'"),
        **overrides,
    }
    values = {k: v for k, v in columns.items() if not hasattr(v, "text")}
    placeholders = ", ".join(v.text if hasattr(v, "text") else f":{k}" for k, v in columns.items())
    await conn.execute(
        text(f"INSERT INTO invites ({', '.join(columns)}) VALUES ({placeholders})"),  # noqa: S608
        values,
    )
    return columns


async def test_a_valid_invite_is_accepted(client: AsyncClient, engine: AsyncEngine) -> None:
    owner = await register(client)
    async with tx(engine) as conn:
        await invite(conn, owner.self_profile_id, owner.id)


async def test_guardian_invites_need_a_managed_profile(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner = await register(client)
    managed = await managed_profile(client, owner)
    async with tx(engine) as conn:
        with pytest.raises(Exception, match="guardian requires a managed profile"):
            await invite(conn, owner.self_profile_id, owner.id, role="guardian")
    async with tx(engine) as conn:
        await invite(conn, managed, owner.id, role="guardian")


@pytest.mark.parametrize(
    ("overrides", "message"),
    [
        ({"role": "owner"}, "role"),
        ({"disclosure_version": 0}, "disclosure_version"),
        ({"expires_at": text("now() - interval '1 second'")}, "expires_after_created"),
        ({"consumed_at": text("now()"), "revoked_at": text("now()")}, "one_end"),
    ],
)
async def test_value_checks(
    client: AsyncClient, engine: AsyncEngine, overrides: dict[str, Any], message: str
) -> None:
    owner = await register(client)
    async with tx(engine) as conn:
        with pytest.raises(Exception, match=message):
            await invite(conn, owner.self_profile_id, owner.id, **overrides)


async def test_token_hashes_are_unique(client: AsyncClient, engine: AsyncEngine) -> None:
    owner = await register(client)
    async with tx(engine) as conn:
        first = await invite(conn, owner.self_profile_id, owner.id)
        with pytest.raises(Exception, match="unique"):
            await invite(conn, owner.self_profile_id, owner.id, token_hash=first["token_hash"])


async def test_deleting_the_accepter_keeps_the_invite_but_forgets_them(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    async with tx(engine) as conn:
        await invite(
            conn,
            owner.self_profile_id,
            owner.id,
            consumed_at=text("now()"),
            consumed_by_user_id=relative.id,
        )
        await conn.execute(text("DELETE FROM users WHERE id = :u"), {"u": relative.id})
        row = (await conn.execute(text("SELECT consumed_by_user_id FROM invites"))).scalar_one()
        assert row is None


async def test_invites_cascade_with_the_profile_and_the_creator(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner = await register(client)
    managed = await managed_profile(client, owner)
    async with tx(engine) as conn:
        await invite(conn, managed, owner.id)
        await conn.execute(text("DELETE FROM profiles WHERE id = :p"), {"p": managed})
        assert (await conn.execute(text("SELECT count(*) FROM invites"))).scalar_one() == 0
    async with tx(engine) as conn:
        await invite(conn, owner.self_profile_id, owner.id)
        await conn.execute(text("DELETE FROM users WHERE id = :u"), {"u": owner.id})
        assert (await conn.execute(text("SELECT count(*) FROM invites"))).scalar_one() == 0


async def test_the_active_invite_index_is_partial(engine: AsyncEngine) -> None:
    async with engine.connect() as conn:
        defs = [
            r[0]
            for r in await conn.execute(
                text("SELECT indexdef FROM pg_indexes WHERE tablename = 'invites'")
            )
        ]
    flat = [d.replace("(", "").replace(")", "") for d in defs]
    assert any(
        "profile_id" in d and "WHERE consumed_at IS NULL AND revoked_at IS NULL" in d for d in flat
    )
