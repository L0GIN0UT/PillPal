"""Managed profiles after their owner's erasure: hand-over, purge and retention (D1)."""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.grace_helpers import (
    count,
    in_days,
    request_deletion,
    run_erase_job,
    run_retention,
)
from tests.helpers import (
    create_invite,
    create_managed_profile,
    link_accounts,
    register,
)
from tests.sync_helpers import push_as, scoped_pull
from tests.test_sync import med_data, mut
from tests.ward_helpers import (
    ARCHIVE_RETENTION,
    erase_owner,
    grantees_of,
    make_ward,
    profile_row,
    restore_user,
    scope_of,
    ward_rows,
)

# --- after the owner's erasure ------------------------------------------------------------------


async def test_the_erase_hands_the_ward_to_the_earliest_active_co_guardian(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    ward = await make_ward(client)
    rows_before = await ward_rows(engine, ward)
    now = in_days(31)
    assert (await request_deletion(client, ward.owner)).status_code == 204

    report = await run_erase_job(client, now)

    assert report.erased == 1
    row = await profile_row(engine, ward.profile_id)
    assert row["owner_user_id"] == ward.first.id
    assert row["archive_reason"] == "owner_erased"
    purge_after = datetime.fromisoformat(row["archive_purge_after"])
    assert abs(purge_after - (now + ARCHIVE_RETENTION)) < timedelta(seconds=1)
    rows = await ward_rows(engine, ward)
    assert rows["medications"] == rows_before["medications"] == 1  # history intact
    assert rows["dose_events"] == rows_before["dose_events"] == 1
    assert rows["schedules"] == 1
    # The heir's own grant and the viewer's are gone; the other guardian keeps hers.
    grantees = await grantees_of(engine, ward)
    assert grantees == {ward.second.id}
    assert await count(engine, "users", "id = :u", u=uuid.UUID(ward.owner.id)) == 0


async def test_the_heirs_and_the_other_guardians_see_the_archive(client: AsyncClient) -> None:
    ward = await make_ward(client)
    await erase_owner(client, ward)

    heir = await scope_of(client, ward.first, ward.profile_id)
    other = await scope_of(client, ward.second, ward.profile_id)
    assert heir is not None
    assert (heir["role"], heir["archived"]) == ("owner", True)
    assert heir["archive_purge_after"] is not None  # the banner shows when it goes
    assert other is not None
    assert (other["role"], other["archived"]) == ("guardian", True)
    assert await scope_of(client, ward.viewer, ward.profile_id) is None


async def test_device_ids_on_the_transferred_rows_are_cleared(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    ward = await make_ward(client)
    pid = uuid.UUID(ward.profile_id)
    written = await push_as(
        client,
        ward.first,
        [mut("medication", "upsert", str(uuid.uuid4()), med_data(ward.profile_id), 3)],
        device="first-phone",
    )
    assert written[0]["status"] == "applied"
    rows = "profile_id = :p AND updated_by_device <> ''"
    assert await count(engine, "medications", rows, p=pid) == 1  # the precondition

    await erase_owner(client, ward)

    assert await count(engine, "medications", rows, p=pid) == 0
    assert await count(engine, "profiles", "id = :p AND updated_by_device <> ''", p=pid) == 0


async def test_a_pending_co_guardian_is_skipped_for_the_transfer(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    ward = await make_ward(client)
    await request_deletion(client, ward.owner)
    await request_deletion(client, ward.first)  # the earliest co-guardian leaves too

    await run_erase_job(client, in_days(31))

    row = await profile_row(engine, ward.profile_id)
    # The owner went first (earlier request), the profile went to the next active guardian.
    assert row["owner_user_id"] == ward.second.id
    assert await count(engine, "users", "id = :u", u=uuid.UUID(ward.first.id)) == 0


async def test_without_an_active_co_guardian_the_ward_is_erased_with_the_owner(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, viewer, pending = await register(client), await register(client), await register(client)
    alone = await create_managed_profile(client, owner)
    await link_accounts(client, owner, viewer, "viewer", alone)
    guarded = await create_managed_profile(client, owner)
    await link_accounts(client, owner, pending, "guardian", guarded)
    await request_deletion(client, pending)
    await request_deletion(client, owner)

    await run_erase_job(client, in_days(31))

    for pid in (alone, guarded):
        assert await count(engine, "profiles", "id = :p", p=uuid.UUID(pid)) == 0


async def test_an_archive_handed_over_is_not_archived_again_by_the_new_owners_request(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    ward = await make_ward(client)
    await erase_owner(client, ward)
    before = await profile_row(engine, ward.profile_id)

    assert (await request_deletion(client, ward.first)).status_code == 204

    after = await profile_row(engine, ward.profile_id)
    assert after["archive_reason"] == "owner_erased"
    assert after["archived_at"] == before["archived_at"]
    assert after["archive_purge_after"] == before["archive_purge_after"]
    # Restoring the heir does not un-archive it: only owner_pending_deletion profiles revert.
    await restore_user(client, ward.first)
    assert (await profile_row(engine, ward.profile_id))["archive_reason"] == "owner_erased"


async def test_a_second_hand_over_keeps_the_original_purge_date(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    ward = await make_ward(client)
    await erase_owner(client, ward)
    purge_after = (await profile_row(engine, ward.profile_id))["archive_purge_after"]
    await request_deletion(client, ward.first)

    await run_erase_job(client, in_days(80))  # much later: a fresh date would be 80 days later

    row = await profile_row(engine, ward.profile_id)
    assert row["owner_user_id"] == ward.second.id
    assert row["archive_purge_after"] == purge_after


async def test_the_new_owner_cannot_change_an_archive(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    ward = await make_ward(client)
    await erase_owner(client, ward)
    heir = ward.first

    posted = await client.post(
        f"/v1/profiles/{ward.profile_id}/medications",
        json={"id": str(uuid.uuid4()), "name": "N"},
        headers=heir.headers,
    )
    assert (posted.status_code, posted.json()["error"]["code"]) == (409, "read_only")
    invite = await client.post(
        f"/v1/profiles/{ward.profile_id}/invites",
        json={"id": str(uuid.uuid4()), "role": "viewer", "disclosure_version": 1},
        headers=heir.headers,
    )
    assert (invite.status_code, invite.json()["error"]["code"]) == (409, "read_only")
    grant_id = ward.second_grant["id"]
    role = await client.patch(
        f"/v1/grants/{grant_id}",
        json={"role": "viewer", "disclosure_version": 1},
        headers=heir.headers,
    )
    assert (role.status_code, role.json()["error"]["code"]) == (409, "read_only")
    revoke = await client.delete(f"/v1/grants/{grant_id}", headers=heir.headers)
    assert (revoke.status_code, revoke.json()["error"]["code"]) == (409, "read_only")
    # The grantee's own choice stays free on an archive.
    mute = await client.patch(
        f"/v1/grants/{grant_id}", json={"notify_missed": False}, headers=ward.second.headers
    )
    assert mute.status_code == 200
    assert (
        await count(engine, "profile_grants", "profile_id = :p", p=uuid.UUID(ward.profile_id)) == 1
    )


async def test_nobody_can_open_an_invite_to_an_archive(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    ward = await make_ward(client)
    invite = await create_invite(client, ward.owner, ward.profile_id, "viewer")
    from tests.helpers import accept_invite, token_of

    await request_deletion(client, ward.owner)  # revokes the open invite
    outsider = await register(client)
    resp = await accept_invite(client, outsider, token_of(invite))
    assert resp.status_code == 404
    assert resp.json()["error"]["code"] == "invite_invalid"


# --- purge --------------------------------------------------------------------------------------


async def test_a_guardian_purges_the_archive_after_the_owner_is_erased(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    ward = await make_ward(client)
    await erase_owner(client, ward)

    resp = await client.delete(f"/v1/profiles/{ward.profile_id}", headers=ward.second.headers)

    assert resp.status_code == 204
    assert set((await ward_rows(engine, ward)).values()) == {0}  # a purge, not a tombstone
    assert (
        await client.delete(f"/v1/profiles/{ward.profile_id}", headers=ward.second.headers)
    ).status_code == 404
    page = await scoped_pull(client, ward.first, {ward.profile_id: 0})
    assert ward.profile_id in page["revoked"]  # devices evict the scope


async def test_the_new_owner_may_purge_too_and_strangers_may_not(client: AsyncClient) -> None:
    ward = await make_ward(client)
    await erase_owner(client, ward)
    stranger = await register(client)
    assert (
        await client.delete(f"/v1/profiles/{ward.profile_id}", headers=stranger.headers)
    ).status_code == 404
    assert (
        await client.delete(f"/v1/profiles/{ward.profile_id}", headers=ward.viewer.headers)
    ).status_code == 404
    assert (
        await client.delete(f"/v1/profiles/{ward.profile_id}", headers=ward.first.headers)
    ).status_code == 204


async def test_retention_purges_an_archive_when_its_time_has_come(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    ward = await make_ward(client)
    await erase_owner(client, ward)
    purge_after = datetime.fromisoformat(
        (await profile_row(engine, ward.profile_id))["archive_purge_after"]
    )

    early = await run_retention(client, purge_after - timedelta(seconds=1))
    assert early.archives_purged == 0
    assert (await ward_rows(engine, ward))["medications"] == 1

    late = await run_retention(client, purge_after)
    assert late.archives_purged == 1
    assert set((await ward_rows(engine, ward)).values()) == {0}
    assert await count(engine, "users", "id = :u", u=uuid.UUID(ward.first.id)) == 1  # people stay


async def test_an_inherited_archive_cannot_be_purged_while_its_new_owner_is_pending(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    """The heir may still restore, so the others may only leave meanwhile (409 ``read_only``)."""
    ward = await make_ward(client)
    await erase_owner(client, ward)
    assert (await request_deletion(client, ward.first)).status_code == 204

    resp = await client.delete(f"/v1/profiles/{ward.profile_id}", headers=ward.second.headers)

    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "read_only"
    assert (await ward_rows(engine, ward))["medications"] == 1  # nothing was purged

    await restore_user(client, ward.first)
    resp = await client.delete(f"/v1/profiles/{ward.profile_id}", headers=ward.second.headers)
    assert resp.status_code == 204  # after the restore the ordinary rule applies again
