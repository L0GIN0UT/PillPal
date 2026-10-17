"""The personal-data inventory (privacy rule 7): every table and Redis keyspace is classified,
and erasing an account leaves nothing behind in any classified table."""

from __future__ import annotations

import uuid
from typing import Any

from httpx import AsyncClient
from redis.asyncio import Redis
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.services.personal_data import REDIS_KEYSPACES, TABLE_CLASSIFICATION, TableInfo
from tests.conftest import TEST_REDIS_URL
from tests.grace_helpers import delete_and_erase, pending_login, request_deletion
from tests.helpers import (
    create_invite,
    create_managed_profile,
    create_medication,
    create_schedule,
    link_accounts,
    register,
)
from tests.push_helpers import put_token
from tests.push_outbox_helpers import insert_outbox
from tests.test_sync import mut, push


async def insert_alert(engine: AsyncEngine, profile_id: str, medication_id: str) -> uuid.UUID:
    alert_id = uuid.uuid4()
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "INSERT INTO missed_dose_alerts (id, profile_id, medication_id, occurrence_key, "
                "due_at, variant, detected_at) VALUES (:id, :p, :m, :k, now(), 'missed', now())"
            ),
            {
                "id": alert_id,
                "p": uuid.UUID(profile_id),
                "m": uuid.UUID(medication_id),
                "k": f"{uuid.uuid4()}/2026-10-17T08:00",
            },
        )
    return alert_id


async def public_tables(engine: AsyncEngine) -> set[str]:
    async with engine.connect() as conn:
        rows = await conn.execute(
            text("SELECT tablename FROM pg_tables WHERE schemaname = 'public'")
        )
        return {row[0] for row in rows}


async def test_every_table_is_classified(engine: AsyncEngine) -> None:
    tables = await public_tables(engine)
    unclassified = tables - set(TABLE_CLASSIFICATION)
    assert not unclassified, (
        f"classify {sorted(unclassified)} in app/services/personal_data.py "
        "(and add them to erasure and, from Phase 5, export)"
    )
    stale = set(TABLE_CLASSIFICATION) - tables
    assert not stale, f"classified tables that do not exist: {sorted(stale)}"


async def test_owner_columns_exist(engine: AsyncEngine) -> None:
    async with engine.connect() as conn:
        for table, info in TABLE_CLASSIFICATION.items():
            if info.owner_column is None:
                assert info.kind == "system", f"{table}: personal data needs an owner column"
                continue
            found = (
                await conn.execute(
                    text(
                        "SELECT count(*) FROM information_schema.columns "
                        "WHERE table_schema = 'public' AND table_name = :t AND column_name = :c"
                    ),
                    {"t": table, "c": info.owner_column},
                )
            ).scalar_one()
            assert found == 1, f"{table}.{info.owner_column} does not exist"


def test_the_inventory_distinguishes_medical_data() -> None:
    kinds = {name: info.kind for name, info in TABLE_CLASSIFICATION.items()}
    assert kinds["medications"] == kinds["schedules"] == kinds["dose_events"] == "medical"
    assert kinds["profile_grants"] == kinds["invites"] == "personal"
    assert kinds["push_tokens"] == "personal"
    # A queued push about a profile is medical metadata: that something was missed, and when.
    assert kinds["push_outbox"] == "medical"
    assert TableInfo("system", None).owner_ref == "user"


async def test_redis_keys_belong_to_a_declared_keyspace(client: AsyncClient) -> None:
    user = await register(client)
    await client.post("/v1/invites/preview", json={"token": "x"}, headers=user.headers)
    await request_deletion(client, user)
    await pending_login(client, user)  # leaves a restore ticket in Redis
    redis: Redis = Redis.from_url(TEST_REDIS_URL)
    try:
        keys = [k.decode() async for k in redis.scan_iter("*")]
    finally:
        await redis.aclose()
    assert keys
    undeclared = [k for k in keys if not k.startswith(tuple(REDIS_KEYSPACES))]
    assert not undeclared, "declare the keyspace in REDIS_KEYSPACES (app/services/personal_data.py)"


# --- erasure ---------------------------------------------------------------------------------


OWNED_PROFILES = "SELECT id FROM profiles WHERE owner_user_id = :uid"


async def ids(engine: AsyncEngine, sql: str, **params: Any) -> list[uuid.UUID]:
    async with engine.connect() as conn:
        return [row[0] for row in await conn.execute(text(sql), params)]


async def rows_left(engine: AsyncEngine, table: str, info: TableInfo, user_id: str) -> int:
    """Rows of ``table`` that still point at the erased account's data."""
    profiles = OWNED_PROFILES
    medications = f"SELECT id FROM medications WHERE profile_id IN ({profiles})"  # noqa: S608
    where = {
        "user": f"{info.owner_column} = :uid",
        "profile": f"{info.owner_column} IN ({profiles})",
        "medication": f"{info.owner_column} IN ({medications})",
    }[info.owner_ref]
    async with engine.connect() as conn:
        return int(
            (
                await conn.execute(
                    text(f"SELECT count(*) FROM {table} WHERE {where}"),  # noqa: S608
                    {"uid": uuid.UUID(user_id)},
                )
            ).scalar_one()
        )


async def test_erasing_an_account_leaves_no_row_in_any_classified_table(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative, other = [await register(client) for _ in range(3)]
    ward = await create_managed_profile(client, owner)
    medication = await create_medication(client, owner, profile_id=ward)
    await create_schedule(client, owner, medication["id"])
    await push(
        client,
        owner,
        "phone",
        [
            mut(
                "dose_event",
                "upsert",
                str(uuid.uuid4()),
                {
                    "medication_id": medication["id"],
                    "type": "taken",
                    "at": "2026-10-01T08:00:00+00:00",
                },
            )
        ],
    )
    # A grant on the owner's profile (a viewer: a co-guardian would inherit it, see
    # test_managed_archive).
    await link_accounts(client, owner, relative, "viewer", ward)
    await link_accounts(client, other, owner, "editor")  # the owner is a relative of someone else
    await create_invite(client, owner)  # an open invite
    # Push data in both directions: a token and a queued push of the relative about the ward,
    # the owner's token with a push about someone else's profile, and a bystander's own push
    # that must survive.
    for user in (owner, relative, other):
        await put_token(client, user, f"{user.id[:8]}-phone")
    await insert_outbox(engine, relative, ward, medication_id=medication["id"])
    await insert_outbox(engine, owner, other.self_profile_id)
    survivor = await insert_outbox(engine, other, other.self_profile_id)
    await insert_alert(engine, ward, medication["id"])
    other_medication = await create_medication(client, other)
    survivor_alert = await insert_alert(engine, other.self_profile_id, other_medication["id"])
    owned = await ids(engine, OWNED_PROFILES, uid=uuid.UUID(owner.id))

    await delete_and_erase(client, owner)

    for table, info in TABLE_CLASSIFICATION.items():
        if info.owner_column is not None:
            assert await rows_left(engine, table, info, owner.id) == 0, table
    async with engine.connect() as conn:
        addressed = (
            await conn.execute(
                text("SELECT count(*) FROM push_outbox WHERE recipient_user_id = :u"),
                {"u": uuid.UUID(owner.id)},
            )
        ).scalar_one()
        survivors = (await conn.execute(text("SELECT id FROM push_outbox"))).scalars().all()
    assert addressed == 0
    assert survivors == [survivor]  # nothing else is left of the erased account's pushes
    assert await ids(engine, "SELECT id FROM missed_dose_alerts") == [survivor_alert]
    for table in ("profile_grants", "invites", "push_outbox"):  # the relatives' side
        async with engine.connect() as conn:
            left = (
                await conn.execute(
                    text(
                        f"SELECT count(*) FROM {table} "  # noqa: S608
                        f"WHERE {'subject_' if table == 'push_outbox' else ''}profile_id = ANY(:p)"
                    ),
                    {"p": owned},
                )
            ).scalar_one()
        assert left == 0, table
    # Others keep their data; the invite the erased account consumed forgets who did.
    assert (await client.get("/v1/me", headers=other.headers)).status_code == 200
    async with engine.connect() as conn:
        left = (
            await conn.execute(
                text("SELECT count(*) FROM invites WHERE consumed_by_user_id = :u"),
                {"u": uuid.UUID(owner.id)},
            )
        ).scalar_one()
    assert left == 0
    assert (await client.get("/v1/grants", headers=relative.headers)).json()["incoming"] == []
    assert (await client.get("/v1/grants", headers=other.headers)).json()["outgoing"] == []
