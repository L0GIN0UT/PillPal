"""Medication catalog references through sync (milestone 4.6): keep-on-absent, consent, editors."""

from __future__ import annotations

import uuid
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.helpers import User, create_managed_profile, link_accounts, register
from tests.sync_editor_helpers import World, m, world
from tests.sync_helpers import outcome, push_as, sync_all
from tests.test_medication_refs import (
    GTIN,
    INGREDIENT,
    OTHER_GTIN,
    OTHER_PRODUCT,
    PACKAGE,
    PRODUCT,
    REFS,
)

pytestmark = pytest.mark.usefixtures("contributions_on")

CONSENT = {"gtin_link_shared": True, "gtin_link_consent_version": 1}


def med(profile_id: str, **extra: Any) -> dict[str, Any]:
    return {"profile_id": profile_id, "name": "Synthetic Tablet", "tz_mode": "local"} | extra


async def put(
    client: AsyncClient,
    user: User,
    med_id: str,
    data: dict[str, Any],
    seconds: int,
    device: str = "dev-1",
) -> dict[str, Any]:
    results = await push_as(
        client, user, [m("medication", "upsert", med_id, data, seconds)], device
    )
    return results[0]


async def stored(client: AsyncClient, user: User, med_id: str, device: str = "dev-2") -> Any:
    synced = await sync_all(client, user, device=device)
    return synced.by_id(med_id)["data"]


async def create_linked(
    client: AsyncClient, owner: User, *, consent: bool = False, seconds: int = 1
) -> str:
    mid = str(uuid.uuid4())
    extra = CONSENT if consent else {}
    result = await put(
        client, owner, mid, med(owner.self_profile_id, **REFS, **extra), seconds=seconds
    )
    assert outcome(result) == ("applied", None), result
    return mid


# --- round trip and keep-on-absent -----------------------------------------------------


async def test_references_round_trip_through_push_and_pull(client: AsyncClient) -> None:
    owner = await register(client)
    mid = await create_linked(client, owner)
    data = await stored(client, owner, mid)
    assert data["gtin"] == GTIN
    assert data["catalog_product_id"] == PRODUCT
    assert data["catalog_package_id"] == PACKAGE
    assert data["manual_ingredients"][0] == {
        "substance_id": INGREDIENT,
        "name": "Парацетамол",
        "strength_text": "500 мг",
    }
    assert data["gtin_link_shared"] is False


async def test_an_old_client_push_without_the_fields_keeps_them(client: AsyncClient) -> None:
    owner = await register(client)
    mid = await create_linked(client, owner, consent=True)
    # What an installed field-test APK sends: the full state it knows, no new keys.
    result = await put(client, owner, mid, med(owner.self_profile_id, notes="edited"), seconds=10)
    assert outcome(result) == ("applied", None)
    data = await stored(client, owner, mid)
    assert data["notes"] == "edited"
    assert data["gtin"] == GTIN
    assert data["catalog_product_id"] == PRODUCT
    assert data["catalog_composition_id"] is not None
    assert len(data["manual_ingredients"]) == 2
    assert data["gtin_link_shared"] is True
    assert "gtin_link_consent_version" not in data  # write-only


async def test_an_explicit_null_clears_a_reference(client: AsyncClient) -> None:
    owner = await register(client)
    mid = await create_linked(client, owner)
    cleared = {"catalog_package_id": None, "manual_ingredients": None}
    await put(client, owner, mid, med(owner.self_profile_id, **cleared), seconds=10)
    data = await stored(client, owner, mid)
    assert data["catalog_package_id"] is None
    assert data["manual_ingredients"] is None
    assert data["gtin"] == GTIN  # still absent in the payload: kept


async def test_a_push_that_unlinks_everything_resets_the_consent(client: AsyncClient) -> None:
    owner = await register(client)
    mid = await create_linked(client, owner, consent=True)
    unlink = {"gtin": None, "catalog_product_id": None, "catalog_package_id": None}
    await put(client, owner, mid, med(owner.self_profile_id, **unlink), seconds=10)
    data = await stored(client, owner, mid)
    assert data["gtin"] is None
    assert data["gtin_link_shared"] is False


async def test_echoing_pulled_state_back_is_accepted(client: AsyncClient) -> None:
    owner = await register(client)
    mid = await create_linked(client, owner, consent=True)
    pulled = await stored(client, owner, mid)
    echo = {k: v for k, v in pulled.items() if k not in ("id",)}
    result = await put(client, owner, mid, echo, seconds=10)
    assert outcome(result) == ("applied", None), result
    again = await stored(client, owner, mid)
    assert again["gtin_link_consented_at"] == pulled["gtin_link_consented_at"]


async def test_the_server_timestamp_cannot_be_forged(client: AsyncClient) -> None:
    owner = await register(client)
    mid = str(uuid.uuid4())
    forged = med(owner.self_profile_id, **REFS, **CONSENT)
    await put(client, owner, mid, forged | {"gtin_link_consented_at": "2001-01-01T00:00:00Z"}, 1)
    data = await stored(client, owner, mid)
    assert data["gtin_link_consented_at"] is not None
    assert not data["gtin_link_consented_at"].startswith("2001")


async def test_replaying_a_push_is_idempotent(client: AsyncClient) -> None:
    owner = await register(client)
    mid = str(uuid.uuid4())
    mutation = m("medication", "upsert", mid, med(owner.self_profile_id, **REFS, **CONSENT), 1)
    first = await push_as(client, owner, [mutation])
    again = await push_as(client, owner, [mutation])
    assert outcome(first[0]) == outcome(again[0]) == ("applied", None)
    assert first[0]["version"] == again[0]["version"]
    stamp = (await stored(client, owner, mid))["gtin_link_consented_at"]
    assert (await push_as(client, owner, [mutation]))[0]["version"] == first[0]["version"]
    assert (await stored(client, owner, mid))["gtin_link_consented_at"] == stamp


async def test_lww_still_rejects_an_older_write(client: AsyncClient) -> None:
    owner = await register(client)
    mid = await create_linked(client, owner, seconds=20)
    stale = await put(client, owner, mid, med(owner.self_profile_id, gtin=OTHER_GTIN), seconds=5)
    assert stale["status"] == "ignored_stale"
    assert (await stored(client, owner, mid))["gtin"] == GTIN


# --- validation ------------------------------------------------------------------------


async def test_invalid_reference_payloads_are_rejected(client: AsyncClient) -> None:
    owner = await register(client)
    pid = owner.self_profile_id
    too_many = [{"name": f"Synthetic {i}"} for i in range(11)]
    bad: list[dict[str, Any]] = [
        {"gtin": "123"},
        {"gtin": "0460000000001x"},
        {"manual_ingredients": too_many},
        {"catalog_product_id": "nope"},
        {"gtin_link_shared": None},
        {"gtin_link_shared": "true"},
    ]
    for extra in bad:
        result = await put(client, owner, str(uuid.uuid4()), med(pid, **extra), seconds=1)
        assert outcome(result) == ("rejected", "validation_error"), extra


async def test_unknown_consent_version_is_rejected(client: AsyncClient) -> None:
    owner = await register(client)
    data = med(owner.self_profile_id, **REFS, gtin_link_shared=True, gtin_link_consent_version=42)
    result = await put(client, owner, str(uuid.uuid4()), data, seconds=1)
    assert outcome(result) == ("rejected", "unsupported_consent_version")


async def test_the_flag_without_a_link_is_rejected(client: AsyncClient) -> None:
    owner = await register(client)
    data = med(owner.self_profile_id, gtin=GTIN, **CONSENT)  # no product
    result = await put(client, owner, str(uuid.uuid4()), data, seconds=1)
    assert outcome(result) == ("rejected", "gtin_link_needs_gtin_and_product")


# --- consent ---------------------------------------------------------------------------


async def test_the_flag_sets_a_consent_record(client: AsyncClient) -> None:
    owner = await register(client)
    mid = await create_linked(client, owner, consent=True)
    data = await stored(client, owner, mid)
    assert data["gtin_link_shared"] is True
    assert "gtin_link_consent_version" not in data
    assert data["gtin_link_consented_at"] is not None


async def test_a_relink_resets_consent_and_the_next_pull_shows_it(client: AsyncClient) -> None:
    owner = await register(client)
    mid = await create_linked(client, owner, consent=True)
    first = await sync_all(client, owner, device="dev-2")
    assert first.by_id(mid)["data"]["gtin_link_shared"] is True
    # The first device re-links without mentioning the flag; the other device pulls.
    relink = {"catalog_product_id": OTHER_PRODUCT}
    result = await put(client, owner, mid, med(owner.self_profile_id, **relink), seconds=10)
    assert result["status"] == "applied"
    second = await sync_all(client, owner, first.cursors, device="dev-2")
    data = second.by_id(mid)["data"]
    assert data["catalog_product_id"] == OTHER_PRODUCT
    assert data["gtin_link_shared"] is False
    assert data["gtin_link_consented_at"] is None
    assert data["version"] == first.by_id(mid)["data"]["version"] + 1  # one versioned update


async def test_a_gtin_change_resets_consent_unless_it_consents_again(client: AsyncClient) -> None:
    owner = await register(client)
    mid = await create_linked(client, owner, consent=True)
    await put(client, owner, mid, med(owner.self_profile_id, gtin=OTHER_GTIN), seconds=10)
    assert (await stored(client, owner, mid))["gtin_link_shared"] is False
    again = {"gtin": GTIN, **CONSENT}
    await put(client, owner, mid, med(owner.self_profile_id, **again), seconds=20)
    data = await stored(client, owner, mid)
    assert data["gtin_link_shared"] is True
    assert data["gtin"] == GTIN


async def test_the_flag_can_be_withdrawn(client: AsyncClient) -> None:
    owner = await register(client)
    mid = await create_linked(client, owner, consent=True)
    off = med(owner.self_profile_id, gtin_link_shared=False)
    await put(client, owner, mid, off, seconds=10)
    data = await stored(client, owner, mid)
    assert (data["gtin_link_shared"], data["gtin_link_consented_at"]) == (False, None)


async def test_a_deleted_medication_has_no_consent_left(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner = await register(client)
    mid = await create_linked(client, owner, consent=True)
    await push_as(client, owner, [m("medication", "delete", mid, None, 10)])
    async with engine.connect() as conn:
        found = (
            await conn.execute(
                text(
                    "SELECT gtin, catalog_product_id, manual_ingredients, gtin_link_shared, "
                    "gtin_link_consent_version, gtin_link_consented_at FROM medications "
                    "WHERE id = :i"
                ),
                {"i": mid},
            )
        ).one()
    assert tuple(found) == (None, None, None, False, None, None)


# --- guardians and editors -------------------------------------------------------------


async def test_a_guardian_may_consent(client: AsyncClient) -> None:
    owner, guardian = await register(client), await register(client)
    ward = await create_managed_profile(client, owner)
    await link_accounts(client, owner, guardian, "guardian", ward)
    mid = str(uuid.uuid4())
    data = med(ward, **REFS, **CONSENT)
    results = await push_as(client, guardian, [m("medication", "upsert", mid, data)], "g-dev")
    assert outcome(results[0]) == ("applied", None), results[0]
    synced = await sync_all(client, owner, {ward: 0}, device="dev-2")
    assert synced.by_id(mid)["data"]["gtin_link_shared"] is True


async def _opted_in(client: AsyncClient, w: World) -> str:
    mid = str(uuid.uuid4())
    data = med(w.pid, **REFS, **CONSENT)
    assert (await put(client, w.owner, mid, data, seconds=1))["status"] == "applied"
    return mid


async def test_an_editor_edit_without_the_flag_is_applied_and_keeps_consent(
    client: AsyncClient,
) -> None:
    w = await world(client)
    mid = await _opted_in(client, w)
    # What the current app sends for an editor: the visible fields only.
    edit = med(w.pid, notes="edited by relative")
    results = await push_as(client, w.editor, [m("medication", "upsert", mid, edit)], "e-dev")
    assert outcome(results[0]) == ("applied", None), results[0]
    data = await stored(client, w.owner, mid)
    assert data["notes"] == "edited by relative"
    assert data["gtin_link_shared"] is True
    assert data["gtin"] == GTIN


async def test_an_editor_changing_the_flag_is_forbidden_with_a_projected_current(
    client: AsyncClient,
) -> None:
    w = await world(client)
    mid = await _opted_in(client, w)
    off = med(w.pid, gtin_link_shared=False)
    results = await push_as(client, w.editor, [m("medication", "upsert", mid, off)], "e-dev")
    assert outcome(results[0]) == ("rejected", "forbidden_field")
    shown = results[0]["current"]["data"]
    assert shown["gtin"] == GTIN  # the product reference is visible to relatives
    for hidden in ("gtin_link_shared", "gtin_link_consent_version", "gtin_link_consented_at"):
        assert hidden not in shown
    assert (await stored(client, w.owner, mid))["gtin_link_shared"] is True


async def test_an_editor_cannot_switch_the_flag_on(client: AsyncClient) -> None:
    w = await world(client)
    mid = str(uuid.uuid4())
    await put(client, w.owner, mid, med(w.pid, **REFS), seconds=1)
    on = med(w.pid, gtin_link_shared=True, gtin_link_consent_version=1)
    results = await push_as(client, w.editor, [m("medication", "upsert", mid, on)], "e-dev")
    assert outcome(results[0]) == ("rejected", "forbidden_field")
    assert (await stored(client, w.owner, mid))["gtin_link_shared"] is False


async def test_an_editor_creating_a_medication_cannot_carry_consent(client: AsyncClient) -> None:
    w = await world(client)
    data = med(w.pid, **REFS, **CONSENT)
    results = await push_as(
        client, w.editor, [m("medication", "upsert", str(uuid.uuid4()), data)], "e-dev"
    )
    assert outcome(results[0]) == ("rejected", "forbidden_field")


async def test_an_editor_relink_resets_the_consent_and_never_carries_it(
    client: AsyncClient,
) -> None:
    w = await world(client)
    mid = await _opted_in(client, w)
    relink = med(w.pid, catalog_product_id=OTHER_PRODUCT)
    results = await push_as(client, w.editor, [m("medication", "upsert", mid, relink)], "e-dev")
    assert outcome(results[0]) == ("applied", None), results[0]
    data = await stored(client, w.owner, mid)
    assert data["catalog_product_id"] == OTHER_PRODUCT
    assert data["gtin_link_shared"] is False
    assert data["gtin_link_consented_at"] is None


async def test_an_editor_may_change_a_gtin_and_it_resets_consent(client: AsyncClient) -> None:
    w = await world(client)
    mid = await _opted_in(client, w)
    results = await push_as(
        client, w.editor, [m("medication", "upsert", mid, med(w.pid, gtin=OTHER_GTIN))], "e-dev"
    )
    assert outcome(results[0]) == ("applied", None)
    assert (await stored(client, w.owner, mid))["gtin_link_shared"] is False


# --- privacy projection for relatives --------------------------------------------------


async def test_a_viewer_of_a_shared_medication_sees_references_but_not_the_flag(
    client: AsyncClient,
) -> None:
    w = await world(client)
    mid = await _opted_in(client, w)
    data = (await sync_all(client, w.viewer, {w.pid: 0}, device="v-dev")).by_id(mid)["data"]
    assert data["gtin"] == GTIN
    assert data["catalog_product_id"] == PRODUCT
    assert data["manual_ingredients"][0]["name"] == "Парацетамол"
    for hidden in ("gtin_link_shared", "gtin_link_consent_version", "gtin_link_consented_at"):
        assert hidden not in data


async def test_an_anonymous_medication_shows_no_references(client: AsyncClient) -> None:
    w = await world(client)
    mid = str(uuid.uuid4())
    data = med(w.pid, **REFS, **CONSENT, privacy="anonymous")
    await put(client, w.owner, mid, data, seconds=1)
    shown = (await sync_all(client, w.viewer, {w.pid: 0}, device="v-dev")).by_id(mid)["data"]
    assert shown["redacted"] is True
    blob = str(shown)
    for needle in (GTIN, PRODUCT, PACKAGE, "Парацетамол", "gtin_link"):
        assert needle not in blob


async def test_a_hidden_medication_is_not_delivered(client: AsyncClient) -> None:
    w = await world(client)
    mid = str(uuid.uuid4())
    await put(client, w.owner, mid, med(w.pid, **REFS, privacy="hidden"), seconds=1)
    synced = await sync_all(client, w.viewer, {w.pid: 0}, device="v-dev")
    assert mid not in synced.ids("medication")


async def test_the_owner_gets_every_field_back_on_another_device(client: AsyncClient) -> None:
    w = await world(client)
    mid = await _opted_in(client, w)
    owner_data = await stored(client, w.owner, mid)
    assert owner_data["gtin_link_shared"] is True
    assert owner_data["gtin_link_consented_at"] is not None


# --- a stale device cannot re-grant (the version is write-only) ----------------------------


async def test_a_stale_device_echo_after_a_withdrawal_does_not_grant(client: AsyncClient) -> None:
    owner = await register(client)
    mid = await create_linked(client, owner, consent=True)
    held = (await sync_all(client, owner, device="dev-2")).by_id(mid)["data"]  # shared=true
    off = med(owner.self_profile_id, gtin_link_shared=False)
    await put(client, owner, mid, off, seconds=10)
    echo = {k: v for k, v in held.items() if k != "id"} | {"notes": "edited on the old device"}
    result = await put(client, owner, mid, echo, seconds=20, device="dev-2")
    assert result["status"] == "applied"
    data = await stored(client, owner, mid, device="dev-3")
    assert data["gtin_link_shared"] is False
    assert data["gtin_link_consented_at"] is None
    assert data["notes"] == "edited on the old device"


async def test_a_stale_device_echo_after_a_relink_does_not_grant(client: AsyncClient) -> None:
    owner = await register(client)
    mid = await create_linked(client, owner, consent=True)
    held = (await sync_all(client, owner, device="dev-2")).by_id(mid)["data"]
    relink = med(owner.self_profile_id, catalog_product_id=OTHER_PRODUCT)
    await put(client, owner, mid, relink, seconds=10)
    echo = {k: v for k, v in held.items() if k != "id"}
    await put(client, owner, mid, echo, seconds=20, device="dev-2")
    assert (await stored(client, owner, mid, device="dev-3"))["gtin_link_shared"] is False


async def test_a_relink_with_an_echoed_true_and_no_version_applies_the_relink(
    client: AsyncClient,
) -> None:
    owner = await register(client)
    mid = await create_linked(client, owner, consent=True)
    data = med(
        owner.self_profile_id,
        catalog_product_id=OTHER_PRODUCT,
        gtin_link_shared=True,
        notes="not lost",
    )
    mutation = m("medication", "upsert", mid, data, 10)
    first = await push_as(client, owner, [mutation])
    assert outcome(first[0]) == ("applied", None)
    stored_state = await stored(client, owner, mid)
    assert stored_state["catalog_product_id"] == OTHER_PRODUCT
    assert stored_state["notes"] == "not lost"
    assert stored_state["gtin_link_shared"] is False
    again = await push_as(client, owner, [mutation])  # the replay is idempotent
    assert outcome(again[0]) == ("applied", None)
    assert again[0]["version"] == first[0]["version"]


async def test_an_echo_for_a_pair_that_is_already_consented_changes_nothing(
    client: AsyncClient,
) -> None:
    owner = await register(client)
    mid = await create_linked(client, owner, consent=True)
    before = await stored(client, owner, mid)
    echo = med(owner.self_profile_id, **REFS, gtin_link_shared=True)
    await put(client, owner, mid, echo, seconds=10)
    after = await stored(client, owner, mid)
    assert after["gtin_link_shared"] is True
    assert after["gtin_link_consented_at"] == before["gtin_link_consented_at"]


async def test_a_grant_is_rejected_while_contributions_are_off(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch, settings: Any
) -> None:
    monkeypatch.setattr(settings, "catalog_contributions_enabled", False)
    owner = await register(client)
    data = med(owner.self_profile_id, **REFS, **CONSENT)
    result = await put(client, owner, str(uuid.uuid4()), data, seconds=1)
    assert outcome(result) == ("rejected", "contributions_disabled")
    echo = med(owner.self_profile_id, **REFS, gtin_link_shared=True)  # not a grant: applies
    assert (await put(client, owner, str(uuid.uuid4()), echo, seconds=1))["status"] == "applied"


# --- editors may not touch the consent keys, whatever is stored ----------------------------


@pytest.mark.parametrize("opted_in", [True, False])
@pytest.mark.parametrize(
    "keys",
    [
        {"gtin_link_shared": True},
        {"gtin_link_shared": False},
        {"gtin_link_consent_version": 1},
        {"gtin_link_shared": True, "gtin_link_consent_version": 1},
    ],
)
async def test_an_editor_gets_the_same_answer_whether_or_not_the_owner_opted_in(
    client: AsyncClient, keys: dict[str, Any], opted_in: bool
) -> None:
    w = await world(client)
    mid = str(uuid.uuid4())
    await put(client, w.owner, mid, med(w.pid, **REFS, **(CONSENT if opted_in else {})), 1)
    results = await push_as(
        client, w.editor, [m("medication", "upsert", mid, med(w.pid, **keys))], "e-dev"
    )
    assert outcome(results[0]) == ("rejected", "forbidden_field")
    assert (await stored(client, w.owner, mid))["gtin_link_shared"] is opted_in


async def test_the_editor_refusal_runs_after_the_conflict_rules(client: AsyncClient) -> None:
    w = await world(client)
    mid = await _opted_in(client, w)
    await put(client, w.owner, mid, med(w.pid, **REFS, notes="newer"), seconds=40)
    stale = m("medication", "upsert", mid, med(w.pid, gtin_link_shared=False), 2)
    results = await push_as(client, w.editor, [stale], "e-dev")
    assert results[0]["status"] == "ignored_stale"


async def test_an_editor_relink_replay_is_idempotent(client: AsyncClient) -> None:
    w = await world(client)
    mid = await _opted_in(client, w)
    relink = m("medication", "upsert", mid, med(w.pid, catalog_product_id=OTHER_PRODUCT), 10)
    first = await push_as(client, w.editor, [relink], "e-dev")
    again = await push_as(client, w.editor, [relink], "e-dev")
    assert outcome(first[0]) == outcome(again[0]) == ("applied", None)
    assert first[0]["version"] == again[0]["version"]
