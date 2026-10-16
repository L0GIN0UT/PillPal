"""Database invariants of ``profile_grants`` (ADR 0005 §1): constraints and guard triggers.

Raw SQL on purpose: these rules must hold for any writer, not only for the API.
"""

from __future__ import annotations

import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncConnection, AsyncEngine

from tests.helpers import User, register


async def managed_profile(client: AsyncClient, owner: User) -> str:
    profile_id = str(uuid.uuid4())
    resp = await client.post(
        "/v1/profiles",
        json={"id": profile_id, "display_name": "Synthetic Ward", "timezone": "UTC"},
        headers=owner.headers,
    )
    assert resp.status_code == 201, resp.text
    return profile_id


@asynccontextmanager
async def tx(engine: AsyncEngine) -> AsyncIterator[AsyncConnection]:
    """A transaction that is always rolled back: each statement under test starts clean."""
    async with engine.connect() as conn:
        try:
            yield conn
        finally:
            await conn.rollback()


async def grant(
    conn: AsyncConnection,
    profile_id: str,
    grantee_id: str,
    role: str = "viewer",
    **extra: Any,
) -> None:
    columns = {
        "id": str(uuid.uuid4()),
        "profile_id": profile_id,
        "grantee_user_id": grantee_id,
        "role": role,
        "disclosure_version": 1,
        **extra,
    }
    names = ", ".join(columns)
    params = ", ".join(f":{c}" for c in columns)
    await conn.execute(text(f"INSERT INTO profile_grants ({names}) VALUES ({params})"), columns)  # noqa: S608


async def test_a_grant_for_another_account_is_accepted(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    async with tx(engine) as conn:
        await grant(conn, owner.self_profile_id, relative.id, "viewer")
        row = (
            await conn.execute(
                text("SELECT notify_missed, invite_id, created_at <= now() FROM profile_grants")
            )
        ).one()
        assert tuple(row) == (True, None, True)


async def test_the_owner_cannot_hold_a_grant_on_their_own_profile(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner = await register(client)
    async with tx(engine) as conn:
        with pytest.raises(Exception, match="grantee is the owner"):
            await grant(conn, owner.self_profile_id, owner.id)


async def test_guardian_is_only_allowed_on_managed_profiles(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    managed = await managed_profile(client, owner)
    async with tx(engine) as conn:
        with pytest.raises(Exception, match="guardian requires a managed profile"):
            await grant(conn, owner.self_profile_id, relative.id, "guardian")
    async with tx(engine) as conn:
        await grant(conn, managed, relative.id, "guardian")


async def test_changing_a_role_to_guardian_on_a_self_profile_is_rejected(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    async with tx(engine) as conn:
        await grant(conn, owner.self_profile_id, relative.id, "viewer")
        await conn.execute(text("UPDATE profile_grants SET role = 'editor'"))
        with pytest.raises(Exception, match="guardian requires a managed profile"):
            await conn.execute(text("UPDATE profile_grants SET role = 'guardian'"))


async def test_no_grant_on_a_tombstoned_profile(client: AsyncClient, engine: AsyncEngine) -> None:
    owner, relative = await register(client), await register(client)
    managed = await managed_profile(client, owner)
    deleted = await client.delete(f"/v1/profiles/{managed}", headers=owner.headers)
    assert deleted.status_code == 204
    async with tx(engine) as conn:
        with pytest.raises(Exception, match="profile is deleted"):
            await grant(conn, managed, relative.id, "viewer")


async def test_notify_missed_can_change_on_a_tombstoned_profile(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    """The trigger fires on INSERT and role changes only, so PATCH notify_missed always works."""
    owner, relative = await register(client), await register(client)
    managed = await managed_profile(client, owner)
    async with engine.begin() as conn:
        await grant(conn, managed, relative.id, "viewer")
    assert (
        await client.delete(f"/v1/profiles/{managed}", headers=owner.headers)
    ).status_code == 204
    async with tx(engine) as conn:
        result = await conn.execute(text("UPDATE profile_grants SET notify_missed = false"))
        assert result.rowcount == 1
        with pytest.raises(Exception, match="profile is deleted"):
            await conn.execute(text("UPDATE profile_grants SET role = 'editor'"))


async def test_a_profile_cannot_move_to_an_owner_who_holds_a_grant_on_it(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative, other = await register(client), await register(client), await register(client)
    managed = await managed_profile(client, owner)
    async with engine.begin() as conn:
        await grant(conn, managed, relative.id, "guardian")
    async with tx(engine) as conn:
        with pytest.raises(Exception, match="grantee is the owner"):
            await conn.execute(
                text("UPDATE profiles SET owner_user_id = :u WHERE id = :p"),
                {"u": relative.id, "p": managed},
            )
    async with tx(engine) as conn:  # an account without a grant may take over
        result = await conn.execute(
            text("UPDATE profiles SET owner_user_id = :u WHERE id = :p"),
            {"u": other.id, "p": managed},
        )
        assert result.rowcount == 1


async def test_other_profile_updates_do_not_touch_the_owner_guard(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    managed = await managed_profile(client, owner)
    async with tx(engine) as conn:
        await grant(conn, managed, relative.id, "guardian")
        result = await conn.execute(
            text("UPDATE profiles SET timezone = 'Europe/Berlin' WHERE id = :p"), {"p": managed}
        )
        assert result.rowcount == 1


async def test_one_grant_per_profile_and_grantee(client: AsyncClient, engine: AsyncEngine) -> None:
    owner, relative = await register(client), await register(client)
    async with tx(engine) as conn:
        await grant(conn, owner.self_profile_id, relative.id, "viewer")
        with pytest.raises(Exception, match="unique"):
            await grant(conn, owner.self_profile_id, relative.id, "editor")


@pytest.mark.parametrize(
    ("extra", "role", "message"),
    [({}, "owner", "role"), ({"disclosure_version": 0}, "viewer", "disclosure_version")],
)
async def test_value_checks(
    client: AsyncClient, engine: AsyncEngine, extra: dict[str, Any], role: str, message: str
) -> None:
    owner, relative = await register(client), await register(client)
    async with tx(engine) as conn:
        with pytest.raises(Exception, match=message):
            await grant(conn, owner.self_profile_id, relative.id, role, **extra)


async def test_grants_cascade_with_the_profile_and_the_grantee(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    managed = await managed_profile(client, owner)
    async with tx(engine) as conn:
        await grant(conn, managed, relative.id, "viewer")
        await conn.execute(text("DELETE FROM profiles WHERE id = :p"), {"p": managed})
        assert (await conn.execute(text("SELECT count(*) FROM profile_grants"))).scalar_one() == 0
    async with tx(engine) as conn:
        await grant(conn, owner.self_profile_id, relative.id, "viewer")
        await conn.execute(text("DELETE FROM users WHERE id = :u"), {"u": relative.id})
        assert (await conn.execute(text("SELECT count(*) FROM profile_grants"))).scalar_one() == 0


async def test_the_grant_indexes_exist(engine: AsyncEngine) -> None:
    async with engine.connect() as conn:
        defs = [
            r[0]
            for r in await conn.execute(
                text("SELECT indexdef FROM pg_indexes WHERE tablename = 'profile_grants'")
            )
        ]
    assert any("(grantee_user_id)" in d for d in defs)
    assert any("(profile_id, role, created_at)" in d for d in defs)
    assert any("UNIQUE" in d and "(profile_id, grantee_user_id)" in d for d in defs)


async def test_moving_a_grant_to_another_profile_or_grantee_is_guarded(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    ward = await managed_profile(client, owner)
    async with tx(engine) as conn:
        await grant(conn, ward, relative.id, "guardian")
        with pytest.raises(Exception, match="guardian requires a managed profile"):
            await conn.execute(
                text("UPDATE profile_grants SET profile_id = :p"), {"p": owner.self_profile_id}
            )
    async with tx(engine) as conn:
        await grant(conn, ward, relative.id, "viewer")
        with pytest.raises(Exception, match="grantee is the owner"):
            await conn.execute(
                text("UPDATE profile_grants SET grantee_user_id = :u"), {"u": owner.id}
            )


async def test_a_profile_kind_never_changes(client: AsyncClient, engine: AsyncEngine) -> None:
    owner = await register(client)
    ward = await managed_profile(client, owner)
    async with tx(engine) as conn:
        with pytest.raises(Exception, match="kind is immutable"):
            await conn.execute(
                text("UPDATE profiles SET kind = 'managed' WHERE id = :p"),
                {"p": owner.self_profile_id},
            )
    async with tx(engine) as conn:
        with pytest.raises(Exception, match="kind is immutable"):
            await conn.execute(text("UPDATE profiles SET kind = 'self' WHERE id = :p"), {"p": ward})
    async with tx(engine) as conn:  # an update that leaves kind alone is fine
        result = await conn.execute(
            text("UPDATE profiles SET kind = kind, timezone = 'UTC' WHERE id = :p"), {"p": ward}
        )
        assert result.rowcount == 1
