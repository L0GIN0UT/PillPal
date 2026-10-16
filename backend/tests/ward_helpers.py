"""Shared fixtures of the managed-archive suites: a ward with owner, guardians and a viewer."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import timedelta
from typing import Any

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.grace_helpers import (
    count,
    in_days,
    request_deletion,
    run_erase_job,
    scalar,
)
from tests.helpers import (
    User,
    create_managed_profile,
    create_medication,
    create_schedule,
    link_accounts,
    register,
)
from tests.sync_helpers import push_as, scoped_pull
from tests.test_sync import mut

ARCHIVE_RETENTION = timedelta(days=365)


@dataclass
class Ward:
    owner: User
    first: User  # the earliest co-guardian
    second: User
    viewer: User
    profile_id: str
    medication_id: str
    schedule_id: str
    event_id: str
    first_grant: dict[str, Any]
    second_grant: dict[str, Any]
    viewer_grant: dict[str, Any]


async def make_ward(client: AsyncClient) -> Ward:
    owner, first, second, viewer = [await register(client) for _ in range(4)]
    profile_id = await create_managed_profile(client, owner)
    medication = await create_medication(client, owner, profile_id=profile_id, name="Ward Tablet")
    schedule = await create_schedule(client, owner, medication["id"])
    event_id = str(uuid.uuid4())
    results = await push_as(
        client,
        owner,
        [
            mut(
                "dose_event",
                "upsert",
                event_id,
                {
                    "medication_id": medication["id"],
                    "type": "taken",
                    "at": "2026-10-01T08:00:00+00:00",
                    "note": "ward note",
                },
            )
        ],
        device="owner-phone",
    )
    assert results[0]["status"] == "applied"
    first_grant = await link_accounts(client, owner, first, "guardian", profile_id)
    second_grant = await link_accounts(client, owner, second, "guardian", profile_id)
    viewer_grant = await link_accounts(client, owner, viewer, "viewer", profile_id)
    return Ward(
        owner,
        first,
        second,
        viewer,
        profile_id,
        medication["id"],
        schedule["id"],
        event_id,
        first_grant,
        second_grant,
        viewer_grant,
    )


async def scope_of(client: AsyncClient, user: User, profile_id: str) -> dict[str, Any] | None:
    page = await scoped_pull(client, user, {profile_id: 0})
    return next((s for s in page["scopes"] if s["profile_id"] == profile_id), None)


async def profile_row(engine: AsyncEngine, profile_id: str) -> dict[str, Any]:
    row = await scalar(
        engine, "SELECT to_jsonb(p) FROM profiles p WHERE id = :i", i=uuid.UUID(profile_id)
    )
    return dict(row)


async def ward_rows(engine: AsyncEngine, ward: Ward) -> dict[str, int]:
    pid = uuid.UUID(ward.profile_id)
    return {
        "profiles": await count(engine, "profiles", "id = :p", p=pid),
        "medications": await count(engine, "medications", "profile_id = :p", p=pid),
        "schedules": await count(
            engine,
            "schedules",
            "medication_id IN (SELECT id FROM medications WHERE profile_id = :p)",
            p=pid,
        ),
        "dose_events": await count(engine, "dose_events", "profile_id = :p", p=pid),
        "sync_changes": await count(engine, "sync_changes", "profile_id = :p", p=pid),
        "profile_grants": await count(engine, "profile_grants", "profile_id = :p", p=pid),
        "invites": await count(engine, "invites", "profile_id = :p", p=pid),
    }


async def erase_owner(client: AsyncClient, ward: Ward) -> Any:
    assert (await request_deletion(client, ward.owner)).status_code == 204
    return await run_erase_job(client, in_days(31))


async def restore_user(client: AsyncClient, user: User) -> User:
    from tests.grace_helpers import pending_login, restore

    ticket, code = await pending_login(client, user)
    assert (await restore(client, ticket, code)).status_code == 200
    return user


async def grantees_of(engine: AsyncEngine, ward: Ward) -> set[str]:
    from sqlalchemy import text

    async with engine.connect() as conn:
        rows = await conn.execute(
            text("SELECT grantee_user_id FROM profile_grants WHERE profile_id = :p"),
            {"p": uuid.UUID(ward.profile_id)},
        )
        return {str(r[0]) for r in rows}
