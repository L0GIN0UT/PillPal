"""Access service: which role a user has on a profile and which profiles they may see."""

from __future__ import annotations

import uuid
from collections.abc import AsyncIterator, Iterable
from contextlib import asynccontextmanager

from httpx import AsyncClient
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.db.models import Profile
from app.services import access
from tests.helpers import User, register
from tests.test_grant_triggers import grant, managed_profile


@asynccontextmanager
async def session_for(engine: AsyncEngine) -> AsyncIterator[AsyncSession]:
    async with async_sessionmaker(engine, expire_on_commit=False)() as session:
        yield session


async def link(engine: AsyncEngine, profile_id: str, grantee: User, role: str) -> None:
    async with engine.begin() as conn:
        await grant(conn, profile_id, grantee.id, role)


async def visible(
    engine: AsyncEngine, user: User, roles: Iterable[access.Role] | None = None
) -> set[str]:
    async with session_for(engine) as session:
        stmt = (
            access.accessible_profiles(uuid.UUID(user.id), roles)
            if roles
            else (access.accessible_profiles(uuid.UUID(user.id)))
        )
        return {str(pid) for pid in await session.scalars(stmt)}


async def role_of(engine: AsyncEngine, user: User, profile_id: str) -> str | None:
    async with session_for(engine) as session:
        return await access.role_for_profile(session, uuid.UUID(user.id), uuid.UUID(profile_id))


async def test_roles_come_from_ownership_and_grants(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, viewer, editor, guardian, stranger = [await register(client) for _ in range(5)]
    ward = await managed_profile(client, owner)
    await link(engine, owner.self_profile_id, viewer, "viewer")
    await link(engine, owner.self_profile_id, editor, "editor")
    await link(engine, ward, guardian, "guardian")

    assert await role_of(engine, owner, owner.self_profile_id) == "owner"
    assert await role_of(engine, owner, ward) == "owner"  # primary guardian of a managed profile
    assert await role_of(engine, viewer, owner.self_profile_id) == "viewer"
    assert await role_of(engine, editor, owner.self_profile_id) == "editor"
    assert await role_of(engine, guardian, ward) == "guardian"
    assert await role_of(engine, stranger, owner.self_profile_id) is None
    assert await role_of(engine, viewer, ward) is None  # a grant is per profile
    assert await role_of(engine, owner, str(uuid.uuid4())) is None


async def test_a_deleted_profile_has_no_roles(client: AsyncClient, engine: AsyncEngine) -> None:
    owner, guardian = await register(client), await register(client)
    ward = await managed_profile(client, owner)
    await link(engine, ward, guardian, "guardian")
    assert (await client.delete(f"/v1/profiles/{ward}", headers=owner.headers)).status_code == 204
    assert await role_of(engine, owner, ward) is None
    assert await role_of(engine, guardian, ward) is None
    assert ward not in await visible(engine, owner)
    assert ward not in await visible(engine, guardian)


async def test_accessible_profiles_are_owned_plus_granted(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative, stranger = [await register(client) for _ in range(3)]
    ward = await managed_profile(client, owner)
    await link(engine, owner.self_profile_id, relative, "viewer")
    await link(engine, ward, relative, "guardian")

    assert await visible(engine, owner) == {owner.self_profile_id, ward}
    assert await visible(engine, relative) == {
        relative.self_profile_id,
        owner.self_profile_id,
        ward,
    }
    assert await visible(engine, stranger) == {stranger.self_profile_id}


async def test_accessible_profiles_filter_by_role(client: AsyncClient, engine: AsyncEngine) -> None:
    owner, relative = await register(client), await register(client)
    ward = await managed_profile(client, owner)
    await link(engine, owner.self_profile_id, relative, "editor")
    await link(engine, ward, relative, "guardian")

    assert await visible(engine, relative, ["owner"]) == {relative.self_profile_id}
    assert await visible(engine, relative, ["guardian"]) == {ward}
    assert await visible(engine, relative, ["editor", "viewer"]) == {owner.self_profile_id}
    assert await visible(engine, relative, list(access.FULL_ACCESS_ROLES)) == {
        relative.self_profile_id,
        ward,
    }
    assert await visible(engine, owner, ["viewer"]) == set()


async def test_accessible_profiles_work_as_a_subquery(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    await link(engine, owner.self_profile_id, relative, "viewer")
    async with session_for(engine) as session:
        stmt = select(Profile.display_name).where(
            Profile.id.in_(access.accessible_profiles(uuid.UUID(relative.id), ["viewer"]))
        )
        assert len((await session.scalars(stmt)).all()) == 1


def test_full_access_roles_are_owner_and_guardian() -> None:
    assert {"owner", "guardian"} == access.FULL_ACCESS_ROLES
    assert access.is_full_access("guardian")
    assert not access.is_full_access("editor")
