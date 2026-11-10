"""Catalog-contribution consent ledger and withdrawal (Phase 5.2b, ADR 0016 section 4)."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Any

import pytest
from httpx import AsyncClient, Response
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from app.db.models import Medication
from app.services.consent_ledger import granted_version
from tests.grace_helpers import request_deletion
from tests.helpers import (
    User,
    create_managed_profile,
    create_medication,
    link_accounts,
    register,
)
from tests.sync_editor_helpers import m, world
from tests.sync_helpers import outcome, push_as, sync_all
from tests.test_export_archive import archive_of
from tests.test_medication_refs import GTIN, OTHER_GTIN, OTHER_PRODUCT, PRODUCT

pytestmark = pytest.mark.usefixtures("contributions_on")

OPTED_IN: dict[str, Any] = {
    "gtin": GTIN,
    "catalog_product_id": PRODUCT,
    "gtin_link_shared": True,
    "gtin_link_consent_version": 1,
}


def sync_med(profile_id: str, **extra: Any) -> dict[str, Any]:
    return {"profile_id": profile_id, "name": "Synthetic Tablet", "tz_mode": "local"} | extra


async def contribution_rows(engine: AsyncEngine, user: User) -> list[Any]:
    async with engine.connect() as conn:
        found = await conn.execute(
            text(
                "SELECT version, source, accepted_at, withdrawn_at FROM consents "
                "WHERE user_id = :u AND kind = 'catalog_contribution' ORDER BY accepted_at, id"
            ),
            {"u": uuid.UUID(user.id)},
        )
        return list(found.all())


async def journal_size(engine: AsyncEngine) -> int:
    async with engine.connect() as conn:
        return int((await conn.execute(text("SELECT count(*) FROM sync_changes"))).scalar_one())


async def withdraw(client: AsyncClient, user: User) -> Response:
    return await client.post(
        "/v1/me/consents/withdraw", json={"kind": "catalog_contribution"}, headers=user.headers
    )


async def push_med(
    client: AsyncClient, user: User, med_id: str, data: dict[str, Any], seconds: int = 5
) -> dict[str, Any]:
    results = await push_as(client, user, [m("medication", "upsert", med_id, data, seconds)])
    return results[0]


# --- the ledger -------------------------------------------------------------------------------


async def test_a_rest_create_with_consent_records_one_active_row(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    await create_medication(client, user, **OPTED_IN)
    (row,) = await contribution_rows(engine, user)
    assert (row.version, row.source, row.withdrawn_at) == (1, "medication_link", None)


async def test_a_medication_without_consent_records_nothing(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    await create_medication(client, user, gtin=GTIN, catalog_product_id=PRODUCT)
    assert await contribution_rows(engine, user) == []


async def test_a_second_tick_of_the_same_version_adds_no_row(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    await create_medication(client, user, **OPTED_IN)
    await create_medication(client, user, **OPTED_IN)
    assert len(await contribution_rows(engine, user)) == 1


async def test_a_new_version_adds_a_second_active_row(
    client: AsyncClient,
    engine: AsyncEngine,
    monkeypatch: pytest.MonkeyPatch,
    settings: Settings,
) -> None:
    monkeypatch.setattr(settings, "gtin_link_consent_versions", [1, 2])
    user = await register(client)
    await create_medication(client, user, **OPTED_IN)
    await create_medication(client, user, **OPTED_IN | {"gtin_link_consent_version": 2})
    assert [r.version for r in await contribution_rows(engine, user)] == [1, 2]


async def test_a_rest_patch_that_grants_records_and_an_echo_does_not(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    med = await create_medication(client, user, gtin=GTIN, catalog_product_id=PRODUCT)
    url = f"/v1/medications/{med['id']}"
    granted = await client.patch(url, json=OPTED_IN, headers=user.headers)
    assert granted.status_code == 200, granted.text
    assert len(await contribution_rows(engine, user)) == 1
    echo = await client.patch(url, json={"name": "Renamed"}, headers=user.headers)
    assert echo.status_code == 200
    assert len(await contribution_rows(engine, user)) == 1


async def test_a_sync_push_with_consent_records_without_a_journal_entry_of_its_own(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    before = await journal_size(engine)
    data = sync_med(user.self_profile_id, **OPTED_IN)
    result = await push_med(client, user, str(uuid.uuid4()), data)
    assert outcome(result) == ("applied", None), result
    assert len(await contribution_rows(engine, user)) == 1
    assert await journal_size(engine) - before == 1  # the medication only


async def test_replaying_a_push_is_idempotent(client: AsyncClient, engine: AsyncEngine) -> None:
    user = await register(client)
    data = sync_med(user.self_profile_id, **OPTED_IN)
    mutation = m("medication", "upsert", str(uuid.uuid4()), data, 5)
    first = await push_as(client, user, [mutation])
    second = await push_as(client, user, [mutation])
    assert outcome(first[0]) == outcome(second[0]) == ("applied", None)
    assert len(await contribution_rows(engine, user)) == 1


async def test_a_rejected_push_records_nothing(client: AsyncClient, engine: AsyncEngine) -> None:
    user = await register(client)
    bad = OPTED_IN | {"gtin_link_consent_version": 99}
    result = await push_med(client, user, str(uuid.uuid4()), sync_med(user.self_profile_id, **bad))
    assert result["status"] != "applied"
    assert await contribution_rows(engine, user) == []


async def test_an_editor_push_records_nothing_for_anyone(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    w = await world(client)
    mid = str(uuid.uuid4())
    await push_med(client, w.owner, mid, sync_med(w.pid, **OPTED_IN))
    owner_rows = await contribution_rows(engine, w.owner)
    link = {"gtin": GTIN, "catalog_product_id": PRODUCT}
    edit = sync_med(w.pid, name="Edited by relative", **link)
    await push_as(client, w.editor, [m("medication", "upsert", mid, edit, 20)], "e-dev")
    relink = sync_med(w.pid, gtin=OTHER_GTIN, catalog_product_id=OTHER_PRODUCT)
    await push_as(client, w.editor, [m("medication", "upsert", mid, relink, 30)], "e-dev")
    grab = sync_med(w.pid, **OPTED_IN)
    refused = await push_as(client, w.editor, [m("medication", "upsert", mid, grab, 40)], "e-dev")
    assert refused[0]["status"] == "rejected"
    assert await contribution_rows(engine, w.editor) == []
    assert await contribution_rows(engine, w.owner) == owner_rows


# --- granted_version (pure) -------------------------------------------------------------------

T0 = datetime(2026, 11, 10, 12, 0, tzinfo=UTC)
T1 = datetime(2026, 11, 10, 12, 5, tzinfo=UTC)
NO_CONSENT: dict[str, Any] = {
    "gtin_link_shared": False,
    "gtin_link_consent_version": None,
    "gtin_link_consented_at": None,
}
GRANT: dict[str, Any] = {
    "gtin_link_shared": True,
    "gtin_link_consent_version": 3,
    "gtin_link_consented_at": T1,
}


def test_granted_version_for_a_create() -> None:
    assert granted_version(None, GRANT) == 3


def test_granted_version_for_an_unshared_row() -> None:
    assert granted_version(Medication(gtin_link_shared=False), GRANT) == 3


def test_granted_version_for_a_regrant_with_a_new_time() -> None:
    row = Medication(gtin_link_shared=True, gtin_link_consented_at=T0)
    assert granted_version(row, GRANT) == 3


def test_an_echo_of_a_stored_consent_is_no_grant() -> None:
    row = Medication(gtin_link_shared=True, gtin_link_consented_at=T1)
    assert granted_version(row, GRANT) is None


def test_no_consent_in_the_result_is_no_grant() -> None:
    assert granted_version(None, NO_CONSENT) is None


# --- withdrawal -------------------------------------------------------------------------------


async def test_withdraw_stamps_the_records_and_resets_the_links_for_other_devices(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    med = await create_medication(client, user, **OPTED_IN)
    pulled = await sync_all(client, user, device="dev-2")
    version = pulled.by_id(med["id"])["data"]["version"]

    resp = await withdraw(client, user)
    assert (resp.status_code, resp.json()) == (200, {"reset_links": 1})

    (row,) = await contribution_rows(engine, user)
    assert row.withdrawn_at is not None
    assert row.withdrawn_at >= row.accepted_at
    after = await sync_all(client, user, pulled.cursors, device="dev-2")
    data = after.by_id(med["id"])["data"]
    assert data["gtin_link_shared"] is False
    assert data["version"] > version
    assert data["gtin"] == GTIN  # only the consent goes


async def test_a_second_withdraw_changes_nothing(client: AsyncClient, engine: AsyncEngine) -> None:
    user = await register(client)
    await create_medication(client, user, **OPTED_IN)
    assert (await withdraw(client, user)).json() == {"reset_links": 1}
    stamped = await contribution_rows(engine, user)
    journal = await journal_size(engine)
    again = await withdraw(client, user)
    assert (again.status_code, again.json()) == (200, {"reset_links": 0})
    assert await contribution_rows(engine, user) == stamped
    assert await journal_size(engine) == journal


async def test_withdraw_without_anything_given_is_a_noop(client: AsyncClient) -> None:
    user = await register(client)
    resp = await withdraw(client, user)
    assert (resp.status_code, resp.json()) == (200, {"reset_links": 0})


async def test_ticking_again_after_a_withdrawal_records_a_new_row(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    med = await create_medication(client, user, **OPTED_IN)
    await withdraw(client, user)
    again = await client.patch(f"/v1/medications/{med['id']}", json=OPTED_IN, headers=user.headers)
    assert again.status_code == 200, again.text
    rows = await contribution_rows(engine, user)
    assert sorted(r.withdrawn_at is None for r in rows) == [False, True]


async def test_withdraw_touches_only_the_callers_own_profiles(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    mine, other = await register(client), await register(client)
    await create_medication(client, mine, **OPTED_IN)
    theirs = await create_medication(client, other, **OPTED_IN)
    assert (await withdraw(client, mine)).json() == {"reset_links": 1}
    still = await sync_all(client, other)
    assert still.by_id(theirs["id"])["data"]["gtin_link_shared"] is True
    assert [r.withdrawn_at for r in await contribution_rows(engine, other)] == [None]


async def test_withdraw_needs_authentication(client: AsyncClient) -> None:
    resp = await client.post("/v1/me/consents/withdraw", json={"kind": "catalog_contribution"})
    assert resp.status_code == 401


# --- deletion and export ----------------------------------------------------------------------


async def test_a_deletion_request_stamps_the_contribution_record(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    await create_medication(client, user, **OPTED_IN)
    assert (await request_deletion(client, user)).status_code == 204
    (row,) = await contribution_rows(engine, user)
    assert row.withdrawn_at is not None
    assert row.withdrawn_at >= row.accepted_at


async def test_the_export_contains_the_contribution_rows(client: AsyncClient) -> None:
    user = await register(client)
    await create_medication(client, user, **OPTED_IN)
    _raw, members = await archive_of(client, user)
    rows = members["tables/consents.json"]
    assert [(r["kind"], r["source"], r["version"]) for r in rows] == [
        ("catalog_contribution", "medication_link", 1)
    ]


# --- only the owner grants (owner decision 2026-11-10) ------------------------------------------


async def co_guarded(client: AsyncClient) -> tuple[User, User, str]:
    owner, guardian = await register(client), await register(client)
    ward = await create_managed_profile(client, owner)
    await link_accounts(client, owner, guardian, "guardian", ward)
    return owner, guardian, ward


async def test_a_co_guardian_grant_is_refused_on_push_and_records_nothing(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    _owner, guardian, ward = await co_guarded(client)
    mid = str(uuid.uuid4())
    grant = sync_med(ward, **OPTED_IN)
    refused = await push_as(client, guardian, [m("medication", "upsert", mid, grant)], "g-dev")
    assert outcome(refused[0]) == ("rejected", "forbidden_field")
    assert await contribution_rows(engine, guardian) == []


async def test_a_co_guardian_grant_is_refused_on_rest(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, guardian, ward = await co_guarded(client)
    med = await create_medication(
        client, owner, profile_id=ward, gtin=GTIN, catalog_product_id=PRODUCT
    )
    resp = await client.patch(
        f"/v1/medications/{med['id']}", json=OPTED_IN, headers=guardian.headers
    )
    assert (resp.status_code, resp.json()["error"]["code"]) == (403, "forbidden_field")
    create = await client.post(
        f"/v1/profiles/{ward}/medications",
        json={"id": str(uuid.uuid4()), "name": "Synthetic Tablet", **OPTED_IN},
        headers=guardian.headers,
    )
    assert (create.status_code, create.json()["error"]["code"]) == (403, "forbidden_field")
    assert await contribution_rows(engine, guardian) == []


async def test_a_co_guardian_echo_and_other_edit_apply_and_clear_is_allowed(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, guardian, ward = await co_guarded(client)
    mid = str(uuid.uuid4())
    await push_as(client, owner, [m("medication", "upsert", mid, sync_med(ward, **OPTED_IN), 5)])
    echo = sync_med(ward, name="Renamed by guardian", **OPTED_IN)
    applied = await push_as(client, guardian, [m("medication", "upsert", mid, echo, 20)], "g-dev")
    assert outcome(applied[0]) == ("applied", None)
    synced = await sync_all(client, owner, {ward: 0}, device="dev-2")
    data = synced.by_id(mid)["data"]
    assert (data["name"], data["gtin_link_shared"]) == ("Renamed by guardian", True)
    clear = sync_med(
        ward,
        name="Renamed by guardian",
        gtin_link_shared=False,
        gtin=GTIN,
        catalog_product_id=PRODUCT,
    )
    cleared = await push_as(client, guardian, [m("medication", "upsert", mid, clear, 30)], "g-dev")
    assert outcome(cleared[0]) == ("applied", None)
    after = await sync_all(client, owner, {ward: 0}, device="dev-2")
    assert after.by_id(mid)["data"]["gtin_link_shared"] is False
    assert await contribution_rows(engine, guardian) == []
    assert len(await contribution_rows(engine, owner)) == 1


async def test_an_owner_grant_on_a_managed_profile_is_recorded_for_the_owner(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, guardian, ward = await co_guarded(client)
    await create_medication(client, owner, profile_id=ward, **OPTED_IN)
    assert len(await contribution_rows(engine, owner)) == 1
    assert await contribution_rows(engine, guardian) == []


async def test_a_deletion_request_by_the_owner_resets_the_owners_links(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, _guardian, ward = await co_guarded(client)
    med = await create_medication(client, owner, profile_id=ward, **OPTED_IN)
    assert (await request_deletion(client, owner)).status_code == 204
    async with engine.connect() as conn:
        shared = (
            await conn.execute(
                text("SELECT gtin_link_shared FROM medications WHERE id = :i"), {"i": med["id"]}
            )
        ).scalar_one()
    assert shared is False


# --- a stale offline grant after a withdrawal ---------------------------------------------------


async def test_a_grant_older_than_the_withdrawal_does_not_bring_the_consent_back(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    mid = str(uuid.uuid4())
    first = sync_med(user.self_profile_id, **OPTED_IN)
    await push_med(client, user, mid, first, seconds=-60)
    assert (await withdraw(client, user)).json() == {"reset_links": 1}
    stale = sync_med(user.self_profile_id, name="Edited offline", **OPTED_IN)
    result = await push_med(client, user, mid, stale, seconds=-30)
    assert outcome(result) == ("applied", None)
    data = (await sync_all(client, user, device="dev-2")).by_id(mid)["data"]
    assert (data["name"], data["gtin_link_shared"]) == ("Edited offline", False)
    assert [r.withdrawn_at is None for r in await contribution_rows(engine, user)] == [False]


async def test_a_grant_newer_than_the_withdrawal_applies(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    user = await register(client)
    mid = str(uuid.uuid4())
    first = sync_med(user.self_profile_id, **OPTED_IN)
    await push_med(client, user, mid, first, seconds=-60)
    await withdraw(client, user)
    again = sync_med(user.self_profile_id, name="Ticked again", **OPTED_IN)
    assert outcome(await push_med(client, user, mid, again, seconds=5)) == ("applied", None)
    rows = await contribution_rows(engine, user)
    assert sorted(r.withdrawn_at is None for r in rows) == [False, True]
