"""Managed profiles when their owner goes away: the read-only archive (D1, ADR 0005 §5)."""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.grace_helpers import (
    count,
    delete_and_restore,
    in_days,
    request_deletion,
    run_erase_job,
    run_retention,
    scalar,
)
from tests.helpers import (
    User,
    create_invite,
    create_managed_profile,
    create_medication,
    create_schedule,
    link_accounts,
    register,
)
from tests.sync_helpers import push_as, scoped_pull
from tests.test_sync import med_data, mut

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


# --- while the owner can still restore --------------------------------------------------------


async def test_the_request_archives_the_ward_for_its_guardians(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    ward = await make_ward(client)
    assert (await request_deletion(client, ward.owner)).status_code == 204

    row = await profile_row(engine, ward.profile_id)
    assert row["archived_at"] is not None
    assert row["archive_reason"] == "owner_pending_deletion"
    assert row["archive_purge_after"] is None
    for guardian in (ward.first, ward.second):
        scope = await scope_of(client, guardian, ward.profile_id)
        assert scope is not None
        assert (scope["role"], scope["archived"], scope["archive_purge_after"]) == (
            "guardian",
            True,
            None,
        )
        listed = await client.get(
            f"/v1/profiles/{ward.profile_id}/medications", headers=guardian.headers
        )
        assert listed.status_code == 200  # the archive stays readable
        assert [m["id"] for m in listed.json()["items"]] == [ward.medication_id]
    assert await scope_of(client, ward.viewer, ward.profile_id) is None  # viewers lose it


async def test_guardians_cannot_write_to_an_archive(client: AsyncClient) -> None:
    ward = await make_ward(client)
    await request_deletion(client, ward.owner)
    g = ward.first.headers
    now = datetime.now(UTC).isoformat()
    requests: list[tuple[str, str, dict[str, Any] | None]] = [
        (
            "POST",
            f"/v1/profiles/{ward.profile_id}/medications",
            {"id": str(uuid.uuid4()), "name": "N"},
        ),
        ("PATCH", f"/v1/medications/{ward.medication_id}", {"name": "Renamed"}),
        ("DELETE", f"/v1/medications/{ward.medication_id}", None),
        (
            "POST",
            f"/v1/medications/{ward.medication_id}/schedules",
            {
                "id": str(uuid.uuid4()),
                "rule": __import__("tests.helpers", fromlist=["x"]).daily_rule(),
            },
        ),
        ("DELETE", f"/v1/schedules/{ward.schedule_id}", None),
        ("PATCH", f"/v1/profiles/{ward.profile_id}", {"display_name": "Renamed"}),
        (
            "POST",
            "/v1/dose-events",
            {
                "id": str(uuid.uuid4()),
                "medication_id": ward.medication_id,
                "type": "taken",
                "at": now,
            },
        ),
    ]
    for method, url, body in requests:
        resp = await client.request(method, url, json=body, headers=g)
        assert resp.status_code == 409, (method, url, resp.text)
        assert resp.json()["error"]["code"] == "read_only", (method, url)


async def test_sync_writes_to_an_archive_are_read_only_with_the_current_state(
    client: AsyncClient,
) -> None:
    ward = await make_ward(client)
    await request_deletion(client, ward.owner)
    results = await push_as(
        client,
        ward.first,
        [
            mut("medication", "upsert", ward.medication_id, med_data(ward.profile_id, name="X"), 5),
            mut("medication", "upsert", str(uuid.uuid4()), med_data(ward.profile_id), 6),
            mut("medication", "delete", ward.medication_id, None, 7),
            mut(
                "dose_event",
                "upsert",
                str(uuid.uuid4()),
                {
                    "medication_id": ward.medication_id,
                    "type": "taken",
                    "at": "2026-10-02T08:00:00+00:00",
                },
                8,
            ),
            mut("profile", "delete", ward.profile_id, None, 9),
        ],
    )
    assert [(r["status"], r["code"]) for r in results] == [("rejected", "read_only")] * 5
    assert results[0]["current"]["data"]["name"] == "Ward Tablet"  # unchanged, shown back


async def test_guardians_may_only_leave_while_the_owner_can_restore(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    ward = await make_ward(client)
    await request_deletion(client, ward.owner)

    delete = await client.delete(f"/v1/profiles/{ward.profile_id}", headers=ward.first.headers)
    assert delete.status_code == 409
    assert delete.json()["error"]["code"] == "read_only"
    assert (await ward_rows(engine, ward))["medications"] == 1

    leave = await client.delete(f"/v1/grants/{ward.first_grant['id']}", headers=ward.first.headers)
    assert leave.status_code == 204
    assert await scope_of(client, ward.first, ward.profile_id) is None
    assert await scope_of(client, ward.second, ward.profile_id) is not None


async def test_a_restore_unarchives_the_ward_and_guardians_can_write_again(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    ward = await make_ward(client)
    ward.owner = await delete_and_restore(client, ward.owner)

    row = await profile_row(engine, ward.profile_id)
    assert (row["archived_at"], row["archive_reason"]) == (None, None)
    scope = await scope_of(client, ward.first, ward.profile_id)
    assert scope is not None
    assert scope["archived"] is False
    resp = await client.post(
        f"/v1/profiles/{ward.profile_id}/medications",
        json={"id": str(uuid.uuid4()), "name": "After restore"},
        headers=ward.first.headers,
    )
    assert resp.status_code == 201
    assert await scope_of(client, ward.viewer, ward.profile_id) is not None  # grants active again


async def test_a_ward_without_co_guardians_is_archived_too_and_restored(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner = await register(client)
    alone = await create_managed_profile(client, owner)
    await request_deletion(client, owner)
    assert (await profile_row(engine, alone))["archive_reason"] == "owner_pending_deletion"
    owner = await _restore(client, owner)
    assert (await profile_row(engine, alone))["archived_at"] is None
    assert owner.id


async def _restore(client: AsyncClient, user: User) -> User:
    from tests.grace_helpers import pending_login, restore

    ticket, code = await pending_login(client, user)
    assert (await restore(client, ticket, code)).status_code == 200
    return user


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
    grantees = await _grantees(engine, ward)
    assert grantees == {ward.second.id}
    assert await count(engine, "users", "id = :u", u=uuid.UUID(ward.owner.id)) == 0


async def _grantees(engine: AsyncEngine, ward: Ward) -> set[str]:
    from sqlalchemy import text

    async with engine.connect() as conn:
        rows = await conn.execute(
            text("SELECT grantee_user_id FROM profile_grants WHERE profile_id = :p"),
            {"p": uuid.UUID(ward.profile_id)},
        )
        return {str(r[0]) for r in rows}


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
    await _restore(client, ward.first)
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
