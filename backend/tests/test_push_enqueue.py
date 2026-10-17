"""What queues a push: ``enqueue``, an accepted invite (``link_accepted``) and a restored
account (``link_restored``), all in the transaction of the event (ADR 0008 §6)."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.config import Settings
from app.push.base import PushPayload
from app.services.push_outbox import enqueue
from tests.conftest import FakeClock
from tests.grace_helpers import delete_and_restore, request_deletion
from tests.helpers import (
    accept_invite,
    create_invite,
    create_managed_profile,
    link_accounts,
    register,
    token_of,
)
from tests.push_helpers import delete_token, put_token, rows
from tests.push_outbox_helpers import deliver, fake_senders, outbox_rows

NOW = datetime(2026, 10, 17, 12, 0, tzinfo=UTC)


@pytest.fixture
def maker(
    app_and_engine: tuple[object, AsyncEngine], clean_state: None
) -> async_sessionmaker[AsyncSession]:
    return app_and_engine[0].state.sessionmaker  # type: ignore[attr-defined,no-any-return]


async def test_enqueue_adds_one_row_per_token_and_is_idempotent(
    client: AsyncClient, engine: AsyncEngine, maker: async_sessionmaker[AsyncSession]
) -> None:
    user = await register(client)
    await put_token(client, user, "phone")
    await put_token(client, user, "tablet")
    payload = PushPayload(t="missed", a=uuid.uuid4(), p=uuid.UUID(user.self_profile_id))
    for expected in (2, 0):  # the replay adds nothing
        async with maker() as session:
            added = await enqueue(
                session,
                recipient_user_id=uuid.UUID(user.id),
                payload=payload,
                ref=str(payload.a),
                subject_profile_id=uuid.UUID(user.self_profile_id),
                now=NOW,
            )
            await session.commit()
        assert added == expected
    stored = await outbox_rows(engine)
    assert len(stored) == 2
    assert {r.payload["a"] for r in stored} == {str(payload.a)}
    assert {r.status for r in stored} == {"pending"}


async def test_a_recipient_without_a_token_gets_nothing(
    client: AsyncClient, engine: AsyncEngine, maker: async_sessionmaker[AsyncSession]
) -> None:
    user = await register(client)
    payload = PushPayload(t="resolved", a=uuid.uuid4(), p=uuid.UUID(user.self_profile_id))
    async with maker() as session:
        added = await enqueue(
            session,
            recipient_user_id=uuid.UUID(user.id),
            payload=payload,
            ref="x",
            subject_profile_id=uuid.UUID(user.self_profile_id),
            now=NOW,
        )
        await session.commit()
    assert added == 0
    assert await outbox_rows(engine) == []


async def test_accepting_an_invite_tells_the_owner_with_ids_only(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    await put_token(client, owner, "owner-phone")
    grant = await link_accounts(client, owner, relative, "viewer")
    (row,) = await outbox_rows(engine)
    assert row.kind == "link_accepted"
    assert row.recipient_user_id == uuid.UUID(owner.id)
    assert row.subject_profile_id == uuid.UUID(owner.self_profile_id)
    assert row.payload == {
        "v": 1,
        "t": "link_accepted",
        "p": owner.self_profile_id,
        "g": grant["id"],
    }
    # Nothing about the relative, the role or the medications travels.
    assert relative.id not in str(row.payload)
    assert relative.email not in str(row.payload)


async def test_an_owner_without_a_token_is_not_pushed_but_the_link_is_listed(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    await link_accounts(client, owner, relative, "viewer")
    assert await outbox_rows(engine) == []
    assert len((await client.get("/v1/grants", headers=owner.headers)).json()["outgoing"]) == 1


async def test_replaying_an_accept_does_not_push_twice(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    await put_token(client, owner, "owner-phone")
    invite = await create_invite(client, owner)
    assert (await accept_invite(client, relative, token_of(invite))).status_code == 201
    assert (await accept_invite(client, relative, token_of(invite))).status_code == 200
    assert len(await outbox_rows(engine)) == 1


async def test_a_refused_accept_pushes_nothing(client: AsyncClient, engine: AsyncEngine) -> None:
    owner = await register(client)
    await put_token(client, owner, "owner-phone")
    invite = await create_invite(client, owner)
    own = await accept_invite(client, owner, token_of(invite))  # the owner's own profile
    assert own.status_code == 409
    assert await outbox_rows(engine) == []


async def test_every_token_of_a_managed_profiles_owner_is_told(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, guardian = await register(client), await register(client)
    await put_token(client, owner, "phone")
    await put_token(client, owner, "tablet")
    ward = await create_managed_profile(client, owner)
    await link_accounts(client, owner, guardian, "guardian", ward)
    rows_ = await outbox_rows(engine)
    assert len(rows_) == 2
    assert {r.subject_profile_id for r in rows_} == {uuid.UUID(ward)}


async def test_a_restore_tells_the_owners_of_the_profiles_the_account_holds_grants_on(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    first, second, relative, bystander = [await register(client) for _ in range(4)]
    await put_token(client, first, "first-phone")
    await put_token(client, bystander, "bystander-phone")  # holds no link to the relative
    grant_one = await link_accounts(client, first, relative, "viewer")
    grant_two = await link_accounts(client, second, relative, "editor")  # no token: no push
    before = {r.id for r in await outbox_rows(engine)}
    await delete_and_restore(client, relative)
    new = [r for r in await outbox_rows(engine) if r.id not in before]
    assert [(r.kind, r.recipient_user_id) for r in new] == [("link_restored", uuid.UUID(first.id))]
    assert new[0].payload == {
        "v": 1,
        "t": "link_restored",
        "p": first.self_profile_id,
        "g": grant_one["id"],
    }
    assert grant_two["id"] not in str(new[0].payload)


async def test_a_second_deletion_and_restore_tells_again(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    await put_token(client, owner, "owner-phone")
    await link_accounts(client, owner, relative, "viewer")
    restored = await delete_and_restore(client, relative)
    await delete_and_restore(client, restored)
    kinds = [r.kind for r in await outbox_rows(engine)]
    assert kinds.count("link_restored") == 2


async def test_link_pushes_are_delivered_to_the_owner(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
) -> None:
    owner, relative = await register(client), await register(client)
    await put_token(client, owner, "owner-phone")
    await link_accounts(client, owner, relative, "viewer")
    await delete_and_restore(client, relative)
    clock = FakeClock()
    clock.advance(seconds=5)
    senders = fake_senders()
    report = await deliver(maker, settings, senders, clock)
    assert report.sent == 2
    assert [m.payload.t for m in senders["fcm"].sent] == ["link_accepted", "link_restored"]
    assert all(m.payload.m is None and m.payload.a is None for m in senders["fcm"].sent)


async def test_a_pushed_account_that_asks_to_delete_leaves_no_row_to_it(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    await put_token(client, owner, "owner-phone")
    await link_accounts(client, owner, relative, "viewer")
    assert (await request_deletion(client, owner)).status_code == 204
    assert await rows(engine, "SELECT 1 FROM push_outbox") == []
    assert (await delete_token(client, relative)).status_code == 204
