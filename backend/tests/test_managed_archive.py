"""Managed profiles while their owner can still restore: the read-only archive (D1, ADR 0005 §5)."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Any

from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.grace_helpers import (
    delete_and_restore,
    request_deletion,
)
from tests.helpers import (
    create_managed_profile,
    register,
)
from tests.sync_helpers import push_as
from tests.test_sync import med_data, mut
from tests.ward_helpers import (
    make_ward,
    profile_row,
    restore_user,
    scope_of,
    ward_rows,
)

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
    owner = await restore_user(client, owner)
    assert (await profile_row(engine, alone))["archived_at"] is None
    assert owner.id
