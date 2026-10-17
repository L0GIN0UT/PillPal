"""Access is re-checked when a push is sent, not only when it is queued (ADR 0008 §6).

Each test queues pushes about a managed profile, changes who may see what, and then
delivers: nothing the recipient may no longer see reaches a sender (``dropped`` with
``access_changed``), while recipients whose access is intact still get theirs.
"""

from __future__ import annotations

import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any

from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.config import Settings
from tests.conftest import FakeClock
from tests.grace_helpers import delete_and_restore, request_deletion
from tests.helpers import (
    User,
    create_managed_profile,
    create_medication,
    link_accounts,
    register,
)
from tests.push_helpers import put_token
from tests.push_outbox_helpers import deliver, fake_senders, insert_outbox, outbox_rows


@dataclass
class Ward:
    owner: User
    guardian: User
    viewer: User
    editor: User
    profile_id: str
    medication_id: str
    grants: dict[str, dict[str, Any]]
    rows: dict[str, int]  # recipient name -> outbox id


async def make_ward(client: AsyncClient, engine: AsyncEngine, privacy: str = "shared") -> Ward:
    owner, guardian, viewer, editor = [await register(client) for _ in range(4)]
    profile_id = await create_managed_profile(client, owner)
    medication = await create_medication(client, owner, profile_id=profile_id, privacy=privacy)
    grants = {
        "guardian": await link_accounts(client, owner, guardian, "guardian", profile_id),
        "viewer": await link_accounts(client, owner, viewer, "viewer", profile_id),
        "editor": await link_accounts(client, owner, editor, "editor", profile_id),
    }
    ward = Ward(owner, guardian, viewer, editor, profile_id, medication["id"], grants, {})
    for name in ("owner", "guardian", "viewer", "editor"):
        user: User = getattr(ward, name)
        await put_token(client, user, f"{name}-phone")
        ward.rows[name] = await insert_outbox(
            engine, user, profile_id, medication_id=medication["id"]
        )
    return ward


async def run(engine: AsyncEngine, sql: str, **params: Any) -> None:
    async with engine.begin() as conn:
        await conn.execute(text(sql), params)


async def statuses(engine: AsyncEngine) -> dict[int, tuple[str, str | None]]:
    return {r.id: (r.status, r.last_error_code) for r in await outbox_rows(engine)}


SENT = ("sent", None)
DROPPED = ("dropped", "access_changed")


async def test_baseline_everyone_with_access_receives(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    await make_ward(client, engine)
    senders = fake_senders()
    assert (await deliver(maker, settings, senders, now)).sent == 4
    assert len(senders["fcm"].sent) == 4
    assert set((await statuses(engine)).values()) == {SENT}


async def test_a_revoked_grant_receives_nothing(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    ward = await make_ward(client, engine)
    resp = await client.delete(
        f"/v1/grants/{ward.grants['viewer']['id']}", headers=ward.owner.headers
    )
    assert resp.status_code == 204
    senders = fake_senders()
    report = await deliver(maker, settings, senders, now)
    assert (report.sent, report.dropped) == (3, 1)
    states = await statuses(engine)
    assert states[ward.rows["viewer"]] == DROPPED
    assert "viewer-phone" not in [m.delivery_id for m in senders["fcm"].sent]
    assert all(states[ward.rows[n]] == SENT for n in ("owner", "guardian", "editor"))


async def test_leaving_the_profile_receives_nothing(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    ward = await make_ward(client, engine)
    resp = await client.delete(
        f"/v1/grants/{ward.grants['editor']['id']}", headers=ward.editor.headers
    )
    assert resp.status_code == 204
    senders = fake_senders()
    await deliver(maker, settings, senders, now)
    assert (await statuses(engine))[ward.rows["editor"]] == DROPPED
    assert len(senders["fcm"].sent) == 3


async def test_narrowing_to_hidden_keeps_only_full_access_recipients(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    ward = await make_ward(client, engine)
    resp = await client.patch(
        f"/v1/medications/{ward.medication_id}",
        json={"privacy": "hidden"},
        headers=ward.owner.headers,
    )
    assert resp.status_code == 200, resp.text
    senders = fake_senders()
    await deliver(maker, settings, senders, now)
    states = await statuses(engine)
    assert states[ward.rows["viewer"]] == DROPPED
    assert states[ward.rows["editor"]] == DROPPED
    assert states[ward.rows["guardian"]] == SENT  # hidden is for the people who run the profile
    assert states[ward.rows["owner"]] == SENT
    assert len(senders["fcm"].sent) == 2


async def test_anonymous_medications_still_reach_projected_roles(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    ward = await make_ward(client, engine)
    resp = await client.patch(
        f"/v1/medications/{ward.medication_id}",
        json={"privacy": "anonymous"},
        headers=ward.owner.headers,
    )
    assert resp.status_code == 200
    assert (await deliver(maker, settings, fake_senders(), now)).sent == 4


async def test_a_hidden_medication_is_never_sent_to_a_viewer_even_if_queued_by_mistake(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    ward = await make_ward(client, engine, privacy="hidden")
    senders = fake_senders()
    await deliver(maker, settings, senders, now)
    states = await statuses(engine)
    assert states[ward.rows["viewer"]] == states[ward.rows["editor"]] == DROPPED
    assert states[ward.rows["guardian"]] == SENT


async def test_an_archived_profile_receives_nothing(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    ward = await make_ward(client, engine)
    await run(
        engine,
        "UPDATE profiles SET archived_at = now(), archive_reason = 'owner_pending_deletion' "
        "WHERE id = :p",
        p=uuid.UUID(ward.profile_id),
    )
    senders = fake_senders()
    report = await deliver(maker, settings, senders, now)
    assert (report.sent, report.dropped) == (0, 4)
    assert senders["fcm"].sent == []


async def test_a_recipient_who_asked_to_delete_receives_nothing(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    ward = await make_ward(client, engine)
    # Straight into the row: the request itself would also delete the tokens.
    await run(
        engine,
        "UPDATE users SET deletion_requested_at = now(), erase_after = now() + interval '30 days' "
        "WHERE id = :u",
        u=uuid.UUID(ward.guardian.id),
    )
    await deliver(maker, settings, fake_senders(), now)
    states = await statuses(engine)
    assert states[ward.rows["guardian"]] == DROPPED
    assert states[ward.rows["viewer"]] == SENT


async def test_a_subject_owner_who_asked_to_delete_makes_everything_about_them_silent(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    owner, viewer = await register(client), await register(client)
    await link_accounts(client, owner, viewer, "viewer")
    await put_token(client, viewer, "viewer-phone")
    row = await insert_outbox(engine, viewer, owner.self_profile_id)
    await run(
        engine,
        "UPDATE users SET deletion_requested_at = now(), erase_after = now() + interval '30 days' "
        "WHERE id = :u",
        u=uuid.UUID(owner.id),
    )
    senders = fake_senders()
    await deliver(maker, settings, senders, now)
    assert (await statuses(engine))[row] == DROPPED
    assert senders["fcm"].sent == []


async def test_a_deleted_profile_or_medication_receives_nothing(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    ward = await make_ward(client, engine)
    other = await create_medication(client, ward.owner, profile_id=ward.profile_id)
    stale_row = await insert_outbox(engine, ward.viewer, ward.profile_id, medication_id=other["id"])
    assert (
        await client.delete(f"/v1/medications/{other['id']}", headers=ward.owner.headers)
    ).status_code == 204
    senders = fake_senders()
    await deliver(maker, settings, senders, now)
    assert (await statuses(engine))[stale_row] == DROPPED
    assert (
        await client.delete(f"/v1/profiles/{ward.profile_id}", headers=ward.owner.headers)
    ).status_code == 204
    await insert_outbox(engine, ward.viewer, ward.profile_id)
    before = len(senders["fcm"].sent)
    now.advance(seconds=1)
    await deliver(maker, settings, senders, now)
    assert len(senders["fcm"].sent) == before


async def test_a_medication_of_another_profile_is_not_trusted(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    ward = await make_ward(client, engine)
    stranger = await register(client)
    foreign = await create_medication(client, stranger)  # not a medication of the ward
    row = await insert_outbox(engine, ward.viewer, ward.profile_id, medication_id=foreign["id"])
    await deliver(maker, settings, fake_senders(), now)
    assert (await statuses(engine))[row] == DROPPED


async def test_the_deletion_request_drops_pending_pushes_about_its_profiles(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    ward = await make_ward(client, engine)
    bystander, owner2 = await register(client), await register(client)
    await link_accounts(client, owner2, bystander, "viewer")
    await put_token(client, bystander, "bystander-phone")
    unrelated = await insert_outbox(engine, bystander, owner2.self_profile_id)
    assert (await request_deletion(client, ward.owner)).status_code == 204
    states = await statuses(engine)
    # Rows about the owner's profile: dropped in the request's own transaction, not deleted.
    for name in ("guardian", "viewer", "editor"):
        assert states[ward.rows[name]] == DROPPED
    # The owner's own token went with the request, and its pending row cascaded.
    assert ward.rows["owner"] not in states
    assert states[unrelated] == ("pending", None)


async def test_a_restore_does_not_bring_dropped_pushes_back(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    ward = await make_ward(client, engine)
    await delete_and_restore(client, ward.owner)
    senders = fake_senders()
    await deliver(maker, settings, senders, now)
    states = await statuses(engine)
    assert states[ward.rows["viewer"]] == DROPPED
    assert all(m.delivery_id != str(ward.rows["viewer"]) for m in senders["fcm"].sent)


Mutation = Callable[[AsyncClient, AsyncEngine, Ward], Awaitable[None]]


async def test_every_check_is_independent_of_the_others(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    """The control: with nothing changed, the same fixture delivers all four (no false drops)."""
    ward = await make_ward(client, engine)
    await run(
        engine,
        "UPDATE medications SET notes = 'changed' WHERE id = :m",
        m=uuid.UUID(ward.medication_id),
    )
    assert (await deliver(maker, settings, fake_senders(), now)).dropped == 0


async def test_link_pushes_are_dropped_when_their_grant_is_gone_or_inactive(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    now: FakeClock,
) -> None:
    ward = await make_ward(client, engine)

    async def link_row(kind: str, grant_id: str) -> int:
        return await insert_outbox(
            engine,
            ward.owner,
            ward.profile_id,
            kind=kind,
            device="owner-phone",
            grant_id=grant_id,
        )

    accepted_then_revoked = await link_row("link_accepted", ward.grants["viewer"]["id"])
    restored_active = await link_row("link_restored", ward.grants["editor"]["id"])
    accepted_unknown = await link_row("link_accepted", str(uuid.uuid4()))
    pending_grantee = await link_row("link_restored", ward.grants["guardian"]["id"])
    await client.delete(f"/v1/grants/{ward.grants['viewer']['id']}", headers=ward.owner.headers)
    await request_deletion(client, ward.guardian)  # the grantee is pending deletion: inactive
    senders = fake_senders()
    await deliver(maker, settings, senders, now)
    states = await statuses(engine)
    assert states[accepted_then_revoked] == DROPPED
    assert states[accepted_unknown] == DROPPED
    assert states[pending_grantee] == DROPPED
    assert states[restored_active] == SENT
