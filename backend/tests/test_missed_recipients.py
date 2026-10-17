"""Who the detector tells, and what the push may carry (ADR 0007 §2, ADR 0005, ADR 0008)."""

from __future__ import annotations

import uuid

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.config import Settings
from tests.detector_helpers import (
    World,
    alert_rows,
    at,
    check_window,
    make_world,
    missed_pushes,
    recipients_of_pushes,
    register_token,
    set_last_seen,
    sql,
)
from tests.grace_helpers import request_deletion
from tests.helpers import link_accounts, register

Maker = async_sessionmaker[AsyncSession]


async def _tick(maker: Maker, engine: AsyncEngine, settings: Settings) -> int:
    return (await check_window(maker, engine, settings, at(8, 30))).alerts


def _ids(*users: object) -> list[str]:
    return sorted(u.id for u in users)  # type: ignore[attr-defined]


async def test_a_self_owner_is_never_alerted_but_relatives_are(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine)
    await register_token(
        client, world.owner, "owner-phone"
    )  # the owner has local reminders instead
    assert await _tick(maker, engine, settings) == 1
    assert recipients_of_pushes(await missed_pushes(engine)) == _ids(world.relatives["viewer"])


async def test_a_profile_without_relatives_has_nothing_to_alert(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    await make_world(client, engine, relatives=())
    assert await _tick(maker, engine, settings) == 0
    assert await alert_rows(engine) == []


async def test_a_managed_owner_is_alerted_only_when_there_are_co_guardians(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    alone = await make_world(client, engine, managed=True, relatives=())
    await register_token(client, alone.owner, "owner-phone")
    assert await _tick(maker, engine, settings) == 0

    with_viewer = await make_world(client, engine, managed=True, relatives=("viewer",))
    await register_token(client, with_viewer.owner, "owner-phone")
    assert await _tick(maker, engine, settings) == 1
    assert recipients_of_pushes(await missed_pushes(engine)) == _ids(
        with_viewer.relatives["viewer"]
    )


async def test_a_managed_profile_alerts_owner_and_guardians_and_viewers(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine, managed=True, relatives=("guardian", "viewer"))
    await register_token(client, world.owner, "owner-phone")
    assert await _tick(maker, engine, settings) == 1
    [alert] = await alert_rows(engine)
    assert alert.variant == "missed"  # managed profiles are always `missed`
    assert recipients_of_pushes(await missed_pushes(engine)) == _ids(
        world.owner, world.relatives["guardian"], world.relatives["viewer"]
    )


async def test_hidden_medications_alert_full_access_recipients_only(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(
        client, engine, managed=True, relatives=("guardian", "viewer"), privacy="hidden"
    )
    await register_token(client, world.owner, "owner-phone")
    assert await _tick(maker, engine, settings) == 1
    pushes = await missed_pushes(engine)
    assert recipients_of_pushes(pushes) == _ids(world.owner, world.relatives["guardian"])
    assert all(p.payload["m"] == world.medication_id for p in pushes)  # they may know it


async def test_a_hidden_medication_nobody_may_see_makes_no_push(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    await make_world(client, engine, relatives=("viewer", "editor"), privacy="hidden")
    assert await _tick(maker, engine, settings) == 1  # the alert row is the dedupe record
    assert await missed_pushes(engine) == []


async def test_anonymous_medications_alert_everyone_without_the_id_for_relatives(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(
        client, engine, managed=True, relatives=("guardian", "viewer"), privacy="anonymous"
    )
    assert await _tick(maker, engine, settings) == 1
    by_user = {str(p.recipient_user_id): p for p in await missed_pushes(engine)}
    viewer = by_user[world.relatives["viewer"].id]
    guardian = by_user[world.relatives["guardian"].id]
    assert set(viewer.payload) == {"v", "t", "a", "p"}  # time and status only: no `m`
    assert viewer.subject_medication_id is None
    assert guardian.payload["m"] == world.medication_id


async def test_a_push_carries_ids_and_enums_only(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine, relatives=("viewer", "editor"))
    await _tick(maker, engine, settings)
    for push in await missed_pushes(engine):
        assert set(push.payload) <= {"v", "t", "a", "p", "m", "g", "s"}
        flat = " ".join(str(v) for v in push.payload.values())
        assert "Aspirin" not in flat
        assert "08:00" not in flat
        assert world.schedule_id not in flat


async def test_a_grant_made_after_the_dose_was_due_is_not_alerted(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine, relatives=("viewer",))
    late = await register(client)
    await link_accounts(client, world.owner, late, "viewer", world.profile_id)
    await register_token(client, late, "dev-1")
    await sql(
        engine,
        "UPDATE profile_grants SET created_at = :t WHERE grantee_user_id = :u",
        t=at(8, 10),
        u=uuid.UUID(late.id),
    )
    assert await _tick(maker, engine, settings) == 1
    assert recipients_of_pushes(await missed_pushes(engine)) == _ids(world.relatives["viewer"])


async def test_alerts_off_or_muted_alert_nobody(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    off = await make_world(client, engine)
    await sql(
        engine,
        "UPDATE profiles SET missed_alerts_enabled = false WHERE id = :p",
        p=uuid.UUID(off.profile_id),
    )
    assert await _tick(maker, engine, settings) == 0

    await make_world(client, engine)
    await sql(engine, "UPDATE profile_grants SET notify_missed = false")
    assert await _tick(maker, engine, settings) == 0
    assert await alert_rows(engine) == []


async def test_a_muted_relative_is_skipped_but_others_are_alerted(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine, relatives=("viewer", "editor"))
    await sql(
        engine,
        "UPDATE profile_grants SET notify_missed = false WHERE grantee_user_id = :u",
        u=uuid.UUID(world.relatives["viewer"].id),
    )
    assert await _tick(maker, engine, settings) == 1
    assert recipients_of_pushes(await missed_pushes(engine)) == _ids(world.relatives["editor"])


async def test_a_relative_without_a_token_gets_nothing_and_others_still_do(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine, relatives=("viewer", "editor"))
    await sql(
        engine,
        "DELETE FROM push_tokens WHERE user_id = :u",
        u=uuid.UUID(world.relatives["viewer"].id),
    )
    assert await _tick(maker, engine, settings) == 1
    assert recipients_of_pushes(await missed_pushes(engine)) == _ids(world.relatives["editor"])


async def test_archived_profiles_and_pending_owners_are_not_monitored(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    archived = await make_world(client, engine, managed=True, relatives=("guardian",))
    await sql(
        engine,
        "UPDATE profiles SET archived_at = now(), archive_reason = 'owner_erased', "
        "archive_purge_after = now() + interval '30 days' WHERE id = :p",
        p=uuid.UUID(archived.profile_id),
    )
    pending = await make_world(client, engine, relatives=("viewer",))
    assert (await request_deletion(client, pending.owner)).status_code == 204
    assert await _tick(maker, engine, settings) == 0
    assert await alert_rows(engine) == []


async def test_a_pending_recipient_is_excluded(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine, relatives=("viewer", "editor"))
    assert (await request_deletion(client, world.relatives["viewer"])).status_code == 204
    assert await _tick(maker, engine, settings) == 1
    assert recipients_of_pushes(await missed_pushes(engine)) == _ids(world.relatives["editor"])


async def test_tombstoned_profiles_are_not_monitored(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine, managed=True, relatives=("viewer",))
    resp = await client.delete(f"/v1/profiles/{world.profile_id}", headers=world.owner.headers)
    assert resp.status_code == 204, resp.text
    assert await _tick(maker, engine, settings) == 0


async def test_unconfirmed_when_every_owner_device_was_last_seen_before_the_dose(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine)
    await set_last_seen(engine, world.owner, at(7, 59))
    assert await _tick(maker, engine, settings) == 1
    [alert] = await alert_rows(engine)
    assert alert.variant == "unconfirmed"
    [push] = await missed_pushes(engine)
    assert push.payload["s"] == "u"


async def test_a_device_seen_after_the_dose_makes_it_a_plain_missed_alert(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world = await make_world(client, engine)
    await set_last_seen(engine, world.owner, at(8, 10))
    assert await _tick(maker, engine, settings) == 1
    [alert] = await alert_rows(engine)
    assert alert.variant == "missed"
    [push] = await missed_pushes(engine)
    assert "s" not in push.payload


async def test_managed_profiles_are_never_unconfirmed(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    world: World = await make_world(client, engine, managed=True, relatives=("guardian",))
    await set_last_seen(engine, world.owner, at(7, 0))
    assert await _tick(maker, engine, settings) == 1
    [alert] = await alert_rows(engine)
    assert alert.variant == "missed"
