"""Private notes about relatives (ADR 0020 section 4): ``PUT``/``DELETE /v1/relative-notes/{id}``
and the ``notes`` of ``GET /v1/grants``. Only the author ever sees a note."""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from tests.conftest import FakeClock
from tests.grace_helpers import count, run_retention
from tests.helpers import create_managed_profile, link_accounts, register
from tests.relative_note_helpers import delete_note, notes_of, put_note


def error(resp: Any) -> tuple[int, str]:
    return resp.status_code, resp.json()["error"]["code"]


async def test_the_owner_names_a_relative_and_only_the_owner_sees_it(
    client: AsyncClient, clock: FakeClock
) -> None:
    owner, relative = await register(client), await register(client)
    await link_accounts(client, owner, relative)  # relative views the owner's self profile
    resp = await put_note(client, owner, relative.self_profile_id, "  Сын  ")
    assert resp.status_code == 200
    body = resp.json()
    assert (body["profile_id"], body["note"]) == (relative.self_profile_id, "Сын")  # trimmed
    assert datetime.fromisoformat(body["updated_at"]) == clock.now
    grants = (await client.get("/v1/grants", headers=owner.headers)).json()
    assert grants["outgoing"][0]["grantee_profile_id"] == relative.self_profile_id
    assert grants["notes"] == [body]
    relative_view = await client.get("/v1/grants", headers=relative.headers)
    assert relative_view.json()["notes"] == []
    assert "Сын" not in relative_view.text


async def test_a_relative_names_the_owner_and_a_managed_profile(client: AsyncClient) -> None:
    owner, relative = await register(client), await register(client)
    ward = await create_managed_profile(client, owner)
    await link_accounts(client, owner, relative, "editor")
    await link_accounts(client, owner, relative, "guardian", ward)
    assert (await put_note(client, relative, owner.self_profile_id, "Мама")).status_code == 200
    assert (await put_note(client, relative, ward, "Бабушка")).status_code == 200
    assert await notes_of(client, relative) == {owner.self_profile_id: "Мама", ward: "Бабушка"}
    assert await notes_of(client, owner) == {}


async def test_replaying_a_put_changes_nothing_and_a_new_text_replaces(
    client: AsyncClient, clock: FakeClock
) -> None:
    owner, relative = await register(client), await register(client)
    await link_accounts(client, owner, relative)
    first = await put_note(client, owner, relative.self_profile_id, "Сын")
    clock.advance(minutes=5)
    replay = await put_note(client, owner, relative.self_profile_id, "Сын")
    assert replay.status_code == 200
    assert replay.json() == first.json()  # same text: same updated_at
    changed = await put_note(client, owner, relative.self_profile_id, "Сынок")
    assert changed.json()["note"] == "Сынок"
    assert changed.json()["updated_at"] > first.json()["updated_at"]
    assert await notes_of(client, owner) == {relative.self_profile_id: "Сынок"}


async def test_delete_is_idempotent(client: AsyncClient) -> None:
    owner, relative = await register(client), await register(client)
    await link_accounts(client, owner, relative)
    await put_note(client, owner, relative.self_profile_id, "Сын")
    for _ in range(2):
        assert (await delete_note(client, owner, relative.self_profile_id)).status_code == 204
    assert await notes_of(client, owner) == {}


@pytest.mark.parametrize(
    "note",
    [
        "",
        "   ",
        "x" * 21,
        "Сын" + chr(9) + "1",  # tab
        "Сын" + chr(10) + "1",  # newline
        "Сы" + chr(0x85) + "н",  # C1 control inside (at the ends it is trimmed as whitespace)
        chr(0x202E) + "ныС",  # bidi override
        None,
        42,
    ],
)
async def test_bad_notes_are_422(client: AsyncClient, note: Any) -> None:
    owner, relative = await register(client), await register(client)
    await link_accounts(client, owner, relative)
    resp = await put_note(client, owner, relative.self_profile_id, note)
    assert error(resp) == (422, "validation_error")


async def test_body_and_path_are_validated(client: AsyncClient) -> None:
    owner, relative = await register(client), await register(client)
    await link_accounts(client, owner, relative)
    path = f"/v1/relative-notes/{relative.self_profile_id}"
    for body in ({}, {"note": "Сын", "extra": 1}):
        resp = await client.put(path, json=body, headers=owner.headers)
        assert error(resp) == (422, "validation_error")
    resp = await put_note(client, owner, "not-a-uuid", "Сын")
    assert resp.status_code == 422
    assert (await put_note(client, owner, relative.self_profile_id, "x" * 20)).status_code == 200


async def test_notes_need_authentication(client: AsyncClient) -> None:
    owner = await register(client)
    path = f"/v1/relative-notes/{owner.self_profile_id}"
    assert (await client.put(path, json={"note": "Сын"})).status_code == 401
    assert (await client.delete(path)).status_code == 401


async def test_unrelated_profiles_are_404(client: AsyncClient) -> None:
    owner, relative, stranger, cousin = [await register(client) for _ in range(4)]
    own_ward = await create_managed_profile(client, owner)
    await link_accounts(client, owner, relative)
    await link_accounts(client, relative, cousin)  # a relative of my relative is not mine
    for profile_id in (
        stranger.self_profile_id,
        cousin.self_profile_id,
        owner.self_profile_id,  # myself
        own_ward,  # my own managed profile
        str(uuid.uuid4()),
    ):
        assert error(await put_note(client, owner, profile_id, "Сын")) == (404, "not_found")
        assert error(await delete_note(client, owner, profile_id)) == (404, "not_found")


async def test_the_number_of_notes_is_capped(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch, settings: Settings
) -> None:
    monkeypatch.setattr(settings, "max_relative_notes_per_user", 1)
    owner, first, second = [await register(client) for _ in range(3)]
    await link_accounts(client, owner, first)
    await link_accounts(client, owner, second)
    assert (await put_note(client, owner, first.self_profile_id, "Сын")).status_code == 200
    resp = await put_note(client, owner, second.self_profile_id, "Дочь")
    assert error(resp) == (409, "too_many_notes")
    # Changing an existing note is not a new one.
    assert (await put_note(client, owner, first.self_profile_id, "Сынок")).status_code == 200


async def test_note_writes_are_rate_limited(
    client: AsyncClient, monkeypatch: pytest.MonkeyPatch, settings: Settings
) -> None:
    monkeypatch.setattr(settings, "relative_note_rate_limit_attempts", 3)
    owner, relative = await register(client), await register(client)
    await link_accounts(client, owner, relative)
    for note in ("a", "b"):
        assert (await put_note(client, owner, relative.self_profile_id, note)).status_code == 200
    assert (await delete_note(client, owner, relative.self_profile_id)).status_code == 204
    resp = await put_note(client, owner, relative.self_profile_id, "c")
    assert error(resp) == (429, "rate_limited")


async def test_leaving_removes_both_notes_only_with_the_last_link(client: AsyncClient) -> None:
    owner, relative, other = [await register(client) for _ in range(3)]
    ward = await create_managed_profile(client, owner)
    on_self = await link_accounts(client, owner, relative)
    on_ward = await link_accounts(client, owner, relative, "guardian", ward)
    await link_accounts(client, owner, other)
    await put_note(client, owner, relative.self_profile_id, "Сын")
    await put_note(client, owner, other.self_profile_id, "Брат")
    await put_note(client, relative, owner.self_profile_id, "Мама")
    await put_note(client, relative, ward, "Бабушка")

    resp = await client.delete(f"/v1/grants/{on_ward['id']}", headers=relative.headers)
    assert resp.status_code == 204
    # Still linked through the self profile: the people notes stay, the ward note goes.
    assert await notes_of(client, relative) == {owner.self_profile_id: "Мама"}
    assert await notes_of(client, owner) == {
        relative.self_profile_id: "Сын",
        other.self_profile_id: "Брат",
    }

    resp = await client.delete(f"/v1/grants/{on_self['id']}", headers=owner.headers)
    assert resp.status_code == 204
    assert await notes_of(client, relative) == {}
    assert await notes_of(client, owner) == {other.self_profile_id: "Брат"}
    # Re-linking does not bring the old notes back.
    await link_accounts(client, owner, relative)
    assert await notes_of(client, relative) == {}


async def test_retention_sweeps_notes_about_a_deleted_profile(
    client: AsyncClient, engine: AsyncEngine, clock: FakeClock
) -> None:
    owner, relative = await register(client), await register(client)
    ward = await create_managed_profile(client, owner)
    await link_accounts(client, owner, relative)
    await link_accounts(client, owner, relative, "guardian", ward)
    await put_note(client, relative, ward, "Бабушка")
    await put_note(client, relative, owner.self_profile_id, "Мама")
    assert (await client.delete(f"/v1/profiles/{ward}", headers=owner.headers)).status_code == 204
    assert await notes_of(client, relative) == {owner.self_profile_id: "Мама"}

    assert await count(engine, "relative_notes") == 2  # the tombstone keeps the row
    report = await run_retention(client, clock.now + timedelta(days=1))
    assert report.relative_notes_deleted == 1
    assert await count(engine, "relative_notes") == 1
    assert (await run_retention(client, clock.now + timedelta(days=2))).relative_notes_deleted == 0
