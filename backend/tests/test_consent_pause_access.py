"""Relatives, limits and the catalog while a profile is paused (ADR 0016 s.5, owner decisions).

A grant on a paused profile is inactive, like one on a profile whose owner is pending deletion:
the pull drops the scope, REST answers 404, pushes are refused as for a foreign profile. The
owner's own access never changes, and a managed profile is not paused while any guardian
consented. Definition, detector and pushes: ``test_consent_pause.py``.
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from app.errors import AppError
from app.services.catalog_contributions import Confirmation, aggregate_confirmations
from app.services.grants import count_relatives
from app.services.scope_limit import ensure_scope_room
from tests.catalog_helpers import GTIN, PRODUCT, contributor
from tests.consent_pause_helpers import (
    Maker,
    drop_all_consents,
    paused_profiles,
    reaccept,
    withdraw_health,
)
from tests.grace_helpers import request_deletion
from tests.helpers import (
    User,
    accept_invite,
    create_invite,
    create_managed_profile,
    create_medication,
    link_accounts,
    register,
    token_of,
)
from tests.sync_helpers import (
    editor_med,
    make_event,
    make_medication,
    mut,
    outcome,
    push_as,
    scoped_pull,
    sync_all,
)
from tests.ward_helpers import make_ward, scope_of

# --- pull and push ------------------------------------------------------------------------------


async def test_a_relatives_pull_drops_the_scope_while_paused_and_restores_it(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, viewer = await register(client), await register(client)
    medication = await create_medication(client, owner, name="Synthetic Tablet")
    await link_accounts(client, owner, viewer, "viewer")
    before = await sync_all(client, viewer, {viewer.self_profile_id: 0})
    assert medication["id"] in before.ids("medication")

    await withdraw_health(engine, owner)
    page = await scoped_pull(
        client,
        viewer,
        {viewer.self_profile_id: 0, owner.self_profile_id: before.cursors[owner.self_profile_id]},
    )
    assert owner.self_profile_id in page["revoked"]  # the client evicts its copy
    assert owner.self_profile_id not in {s["profile_id"] for s in page["scopes"]}
    assert not [c for c in page["changes"] if c["scope"] == owner.self_profile_id]
    fresh = await sync_all(client, viewer, {viewer.self_profile_id: 0})
    assert owner.self_profile_id not in fresh.scopes
    assert medication["id"] not in fresh.ids("medication")

    await reaccept(client, owner)
    again = await sync_all(client, viewer, {viewer.self_profile_id: 0})
    assert medication["id"] in again.ids("medication")
    assert again.scopes[owner.self_profile_id]["role"] == "viewer"


async def test_an_editors_push_to_a_paused_owner_is_rejected_and_resumes_after(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, editor = await register(client), await register(client)
    await link_accounts(client, owner, editor, "editor")
    await withdraw_health(engine, owner)

    first = mut("medication", "upsert", str(uuid.uuid4()), editor_med(owner.self_profile_id))
    [result] = await push_as(client, editor, [first])
    assert outcome(result) == ("rejected", "parent_not_found")

    await reaccept(client, owner)
    second = mut("medication", "upsert", str(uuid.uuid4()), editor_med(owner.self_profile_id))
    [result] = await push_as(client, editor, [second])
    assert outcome(result) == ("applied", None)


async def test_a_guardians_push_is_rejected_while_nobody_consented(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, guardian = await register(client), await register(client)
    ward = await create_managed_profile(client, owner)
    await link_accounts(client, owner, guardian, "guardian", ward)
    await withdraw_health(engine, owner)
    await withdraw_health(engine, guardian)

    push = mut("medication", "upsert", str(uuid.uuid4()), editor_med(ward))
    [result] = await push_as(client, guardian, [push])
    assert outcome(result) == ("rejected", "parent_not_found")

    await reaccept(client, guardian)
    again = mut("medication", "upsert", str(uuid.uuid4()), editor_med(ward))
    [result] = await push_as(client, guardian, [again])
    assert outcome(result) == ("applied", None)


# --- REST ---------------------------------------------------------------------------------------


async def test_a_guardian_gets_404_over_rest_while_nobody_consented(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, guardian = await register(client), await register(client)
    ward = await create_managed_profile(client, owner)
    medication_id = await make_medication(client, owner, ward)
    event_id = await make_event(client, owner, medication_id)
    await link_accounts(client, owner, guardian, "guardian", ward)
    urls = [
        f"/v1/profiles/{ward}",
        f"/v1/profiles/{ward}/medications",
        f"/v1/medications/{medication_id}",
        f"/v1/dose-events/{event_id}",
    ]
    for url in urls:
        assert (await client.get(url, headers=guardian.headers)).status_code == 200, url

    await withdraw_health(engine, owner)
    await withdraw_health(engine, guardian)

    for url in urls:
        assert (await client.get(url, headers=guardian.headers)).status_code == 404, url
    listed = await client.get(
        "/v1/dose-events", params={"profile_id": ward}, headers=guardian.headers
    )
    assert listed.json()["items"] == []
    profiles = await client.get("/v1/profiles", headers=guardian.headers)
    assert ward not in {p["id"] for p in profiles.json()["items"]}
    for url in urls:  # the owner's own access is unchanged
        assert (await client.get(url, headers=owner.headers)).status_code == 200, url

    await reaccept(client, owner)
    for url in urls:
        assert (await client.get(url, headers=guardian.headers)).status_code == 200, url


async def test_a_paused_owner_keeps_full_access_to_their_own_data(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner = await register(client)
    medication = await create_medication(client, owner, name="Synthetic Tablet")
    await withdraw_health(engine, owner)

    own = await client.get(
        f"/v1/profiles/{owner.self_profile_id}/medications", headers=owner.headers
    )
    assert [m["id"] for m in own.json()["items"]] == [medication["id"]]
    created = await create_medication(client, owner, name="Added while paused")
    synced = await sync_all(client, owner)
    assert {medication["id"], created["id"]} <= synced.ids("medication")
    assert synced.scopes[owner.self_profile_id]["role"] == "owner"
    assert (await client.get("/v1/me/consents", headers=owner.headers)).status_code == 200


# --- managed profiles: any consenting guardian keeps them running (owner decision B) ------------


async def test_a_consented_co_guardian_keeps_scope_rest_and_relatives_of_a_managed_profile(
    client: AsyncClient, engine: AsyncEngine, maker: Maker
) -> None:
    owner, guardian, viewer, editor = [await register(client) for _ in range(4)]
    ward = await create_managed_profile(client, owner)
    medication_id = await make_medication(client, owner, ward)
    for user, role in ((guardian, "guardian"), (viewer, "viewer"), (editor, "editor")):
        await link_accounts(client, owner, user, role, ward)
    await withdraw_health(engine, owner)  # the primary owner is unconsented, the guardian is not

    assert await paused_profiles(maker, ward) == set()
    got = await client.get(f"/v1/medications/{medication_id}", headers=guardian.headers)
    assert got.status_code == 200
    assert ward in (await sync_all(client, viewer)).scopes
    push = mut("medication", "upsert", str(uuid.uuid4()), editor_med(ward))
    assert outcome((await push_as(client, editor, [push]))[0]) == ("applied", None)

    await withdraw_health(engine, guardian)  # nobody is left
    assert await paused_profiles(maker, ward) == {ward}
    assert (
        await client.get(f"/v1/medications/{medication_id}", headers=guardian.headers)
    ).status_code == 404
    assert ward not in (await sync_all(client, viewer)).scopes


async def test_an_archive_after_a_paused_owner_requests_deletion_stays_readable_for_guardians(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    """The archive is exempt from the pause (ADR 0010 D1): guardians read it, viewers do not."""
    ward = await make_ward(client)
    await drop_all_consents(engine)  # nobody consented: the managed profile is paused
    url = f"/v1/profiles/{ward.profile_id}/medications"
    assert (await client.get(url, headers=ward.first.headers)).status_code == 404

    assert (await request_deletion(client, ward.owner)).status_code == 204

    for guardian in (ward.first, ward.second):
        listed = await client.get(url, headers=guardian.headers)
        assert listed.status_code == 200
        scope = await scope_of(client, guardian, ward.profile_id)
        assert scope is not None
        assert scope["archived"] is True
    assert await scope_of(client, ward.viewer, ward.profile_id) is None


# --- grants and invites -------------------------------------------------------------------------


async def test_the_grants_list_marks_a_paused_grant_inactive_and_hides_it_from_the_relative(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, viewer = await register(client), await register(client)
    await link_accounts(client, owner, viewer, "viewer")
    await withdraw_health(engine, owner)

    mine = (await client.get("/v1/grants", headers=owner.headers)).json()
    theirs = (await client.get("/v1/grants", headers=viewer.headers)).json()
    assert [g["active"] for g in mine["outgoing"]] == [False]
    assert theirs["incoming"] == []

    await reaccept(client, owner)
    mine = (await client.get("/v1/grants", headers=owner.headers)).json()
    theirs = (await client.get("/v1/grants", headers=viewer.headers)).json()
    assert [g["active"] for g in mine["outgoing"]] == [True]
    assert len(theirs["incoming"]) == 1


async def test_a_grantee_cannot_patch_a_paused_grant_but_can_always_leave(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    """PATCH would tell a relative that the owner is paused; leaving is never blocked."""
    owner, viewer = await register(client), await register(client)
    grant = await link_accounts(client, owner, viewer, "viewer")
    url = f"/v1/grants/{grant['id']}"
    ok = await client.patch(url, json={"notify_missed": False}, headers=viewer.headers)
    assert ok.status_code == 200

    await withdraw_health(engine, owner)
    paused = await client.patch(url, json={"notify_missed": True}, headers=viewer.headers)
    assert (paused.status_code, paused.json()["error"]["code"]) == (404, "not_found")

    left = await client.delete(url, headers=viewer.headers)
    assert (left.status_code, left.content) == (204, b"")
    assert (await client.get("/v1/grants", headers=owner.headers)).json()["outgoing"] == []


async def test_an_invite_into_a_paused_profile_is_invalid_until_the_owner_consents(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, relative = await register(client), await register(client)
    invite = await create_invite(client, owner)
    await withdraw_health(engine, owner)

    refused = await accept_invite(client, relative, token_of(invite))
    assert (refused.status_code, refused.json()["error"]["code"]) == (404, "invite_invalid")

    await reaccept(client, owner)
    assert (await accept_invite(client, relative, token_of(invite))).status_code == 201


# --- limits count every grant, paused or not ----------------------------------------------------


async def test_the_relatives_limit_counts_paused_grants(
    client: AsyncClient, engine: AsyncEngine, maker: Maker
) -> None:
    owner = await register(client)
    for _ in range(2):
        await link_accounts(client, owner, await register(client), "viewer")
    await withdraw_health(engine, owner)
    async with maker() as session:
        assert await count_relatives(session, uuid.UUID(owner.id)) == 2


async def test_the_scope_limit_counts_paused_scopes(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: Maker,
    settings: Settings,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    owner, relative = await register(client), await register(client)
    await link_accounts(client, owner, relative, "viewer")
    await withdraw_health(engine, owner)
    monkeypatch.setattr(settings, "max_access_scopes_per_user", 2)  # own profile + the grant
    async with maker() as session:
        with pytest.raises(AppError) as raised:
            await ensure_scope_room(session, settings, uuid.UUID(relative.id))
    assert raised.value.code == "too_many_scopes"


# --- the catalog --------------------------------------------------------------------------------


@pytest.mark.usefixtures("contributions_on")
async def test_a_paused_profile_is_not_counted_in_the_catalog_aggregate(
    client: AsyncClient, engine: AsyncEngine, maker: Maker, settings: Settings
) -> None:
    owners: list[User] = [await contributor(client, engine) for _ in range(3)]

    async def counted() -> list[Confirmation]:
        return await aggregate_confirmations(maker, settings, datetime.now(UTC))

    assert await counted() == [Confirmation(GTIN, PRODUCT, 3)]
    await withdraw_health(engine, owners[0])
    assert await counted() == [Confirmation(GTIN, PRODUCT, 2)]
    await withdraw_health(engine, owners[1])
    assert await counted() == []  # below the reporting minimum
    await reaccept(client, owners[0])
    await reaccept(client, owners[1])
    assert await counted() == [Confirmation(GTIN, PRODUCT, 3)]
