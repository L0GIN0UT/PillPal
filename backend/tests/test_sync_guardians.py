"""Sync push: guardians, owner/editor convergence, deleted scopes (ADR 0006 §6)."""

from __future__ import annotations

import uuid

import pytest
from httpx import AsyncClient

from tests.helpers import create_managed_profile, link_accounts, register
from tests.sync_editor_helpers import (
    at,
    m,
    med,
    world,
)
from tests.sync_helpers import (
    make_medication,
    make_schedule,
    outcome,
    push_as,
    sync_all,
)

# --- guardians: full access, except deleting the managed profile ------------------------------


async def test_a_guardian_has_full_access_but_cannot_delete_the_managed_profile(
    client: AsyncClient,
) -> None:
    owner, guardian = await register(client), await register(client)
    ward = await create_managed_profile(client, owner)
    await link_accounts(client, owner, guardian, "guardian", ward)
    hidden = await make_medication(client, owner, ward, "hidden")
    sid = await make_schedule(client, owner, hidden)
    event = str(uuid.uuid4())
    results = await push_as(
        client,
        guardian,
        [
            m("medication", "upsert", hidden, med(ward, privacy="anonymous")),
            m("schedule", "delete", sid),
            m(
                "dose_event",
                "upsert",
                event,
                {"medication_id": hidden, "type": "taken", "at": at(0)},
            ),
            m(
                "profile",
                "upsert",
                ward,
                {"kind": "managed", "display_name": "Renamed", "timezone": "UTC"},
            ),
            m("profile", "delete", ward),
        ],
    )
    assert [outcome(r) for r in results] == [
        ("applied", None),
        ("applied", None),
        ("applied", None),
        ("applied", None),
        ("rejected", "forbidden"),
    ]
    assert results[4]["current"]["data"]["display_name"] == "Renamed"  # full, not projected
    stored = await client.get(f"/v1/profiles/{ward}", headers=owner.headers)
    assert stored.status_code == 200
    gone = await push_as(client, owner, [m("profile", "delete", ward, seconds=10)])
    assert outcome(gone[0]) == ("applied", None)
    assert (await client.get(f"/v1/profiles/{ward}", headers=owner.headers)).status_code == 404


# --- convergence of owner and editor ----------------------------------------------------------


@pytest.mark.parametrize("editor_first", [True, False])
async def test_owner_and_editor_converge_whatever_the_arrival_order(
    client: AsyncClient, editor_first: bool
) -> None:
    w = await world(client)
    mid = w.levels["shared"].medication
    editor_write = m("medication", "upsert", mid, med(w.pid, name="Editor"), seconds=20)
    owner_write = m("medication", "upsert", mid, med(w.pid, name="Owner"), seconds=10)
    sequence = [(w.editor, editor_write, "e-dev"), (w.owner, owner_write, "o-dev")]
    if not editor_first:
        sequence.reverse()
    outcomes = [
        outcome((await push_as(client, who, [mut_], device=dev))[0]) for who, mut_, dev in sequence
    ]
    expected = ["applied", "ignored_stale"] if editor_first else ["applied", "applied"]
    assert [o[0] for o in outcomes] == expected
    owner_sees = (await sync_all(client, w.owner)).by_id(mid)["data"]["name"]
    editor_sees = (await sync_all(client, w.editor, {w.pid: 0})).by_id(mid)["data"]["name"]
    assert owner_sees == editor_sees == "Editor"  # the newer timestamp wins everywhere


async def test_equal_timestamps_are_broken_by_the_device_id_for_both_roles(
    client: AsyncClient,
) -> None:
    w = await world(client)
    mid = w.levels["shared"].medication
    stamp = at(30)
    owner_write = {
        **m("medication", "upsert", mid, med(w.pid, name="Owner")),
        "client_updated_at": stamp,
    }
    editor_write = {
        **m("medication", "upsert", mid, med(w.pid, name="Editor")),
        "client_updated_at": stamp,
    }
    await push_as(client, w.owner, [owner_write], device="aaa-owner")
    result = await push_as(client, w.editor, [editor_write], device="zzz-editor")
    assert outcome(result[0]) == ("applied", None)  # the larger device id wins the tie
    stale = await push_as(client, w.owner, [owner_write], device="aaa-owner")
    assert outcome(stale[0]) == ("ignored_stale", None)
    assert stale[0]["current"]["data"]["name"] == "Editor"
    assert stale[0]["current"]["updated_by_device"] == "zzz-editor"  # the owner sees the device


async def test_ignored_stale_current_is_projected_for_an_editor(client: AsyncClient) -> None:
    w = await world(client)
    mid = w.levels["shared"].medication
    await push_as(
        client,
        w.owner,
        [m("medication", "upsert", mid, med(w.pid, name="Newer"), 60)],
        device="o-dev",
    )
    stale = await push_as(
        client,
        w.editor,
        [m("medication", "upsert", mid, med(w.pid, name="Older"), 5)],
        device="e-dev",
    )
    assert outcome(stale[0]) == ("ignored_stale", None)
    assert stale[0]["current"]["data"]["name"] == "Newer"
    assert stale[0]["current"]["updated_by_device"] is None


# --- deleted scopes ----------------------------------------------------------------------


async def test_a_deleted_managed_profile_is_gone_for_guardians_but_idempotent_for_its_owner(
    client: AsyncClient,
) -> None:
    owner, guardian = await register(client), await register(client)
    ward = await create_managed_profile(client, owner)
    await link_accounts(client, owner, guardian, "guardian", ward)
    mid = await make_medication(client, owner, ward)
    assert (await client.delete(f"/v1/profiles/{ward}", headers=owner.headers)).status_code == 204
    profile = {"kind": "managed", "display_name": "Zombie", "timezone": "UTC"}
    guardian_results = await push_as(
        client,
        guardian,
        [
            m("profile", "upsert", ward, profile),
            m("medication", "upsert", str(uuid.uuid4()), med(ward)),
            m("medication", "upsert", mid, med(ward)),
        ],
    )
    assert [outcome(r) for r in guardian_results] == [
        ("rejected", "not_found"),
        ("rejected", "parent_not_found"),
        ("rejected", "not_found"),
    ]
    owner_results = await push_as(
        client,
        owner,
        [m("profile", "delete", ward, seconds=30), m("profile", "upsert", ward, profile, 30)],
    )
    assert outcome(owner_results[0]) == ("applied", None)
    assert outcome(owner_results[1]) == ("ignored_stale", "deleted")  # tombstones are terminal
    assert owner_results[1]["current"]["data"] is None
