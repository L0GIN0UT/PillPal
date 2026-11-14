"""A person's own name: required at sign-up, 2..20 characters, renamed only within the rule.

The name is the ``display_name`` of the ``self`` profile; relatives see it (invites, grants).
Managed profiles keep the wider ``DisplayName`` rule (1..100).
"""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from httpx import AsyncClient
from pydantic import TypeAdapter, ValidationError
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.validators import PERSON_NAME_MAX, PERSON_NAME_MIN, PersonName, is_person_name
from tests.helpers import BASELINE_CONSENTS, User, register
from tests.oauth_helpers import sign_in, sign_up, ticket_of

PERSON_NAME = TypeAdapter(PersonName)


# --- the validator ------------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("raw", "stored"),
    [
        ("Аня", "Аня"),
        ("  Ivan  ", "Ivan"),
        ("Jo", "Jo"),
        ("x" * PERSON_NAME_MAX, "x" * PERSON_NAME_MAX),
        ("Мария-Луиза Петрова", "Мария-Луиза Петрова"),
    ],
)
def test_person_name_accepts_and_trims(raw: str, stored: str) -> None:
    assert PERSON_NAME.validate_python(raw) == stored
    assert is_person_name(raw)


@pytest.mark.parametrize(
    "raw",
    ["", "   ", "A", " A ", "x" * (PERSON_NAME_MAX + 1), "Iv\x00an", "Iv\x1ban", "Ivan\x7f"],
)
def test_person_name_rejects(raw: str) -> None:
    with pytest.raises(ValidationError):
        PERSON_NAME.validate_python(raw)
    assert not is_person_name(raw)


def test_person_name_bounds_are_two_and_twenty() -> None:
    assert (PERSON_NAME_MIN, PERSON_NAME_MAX) == (2, 20)


# --- e-mail registration ------------------------------------------------------------------------


def _register_body(**overrides: Any) -> dict[str, Any]:
    body: dict[str, Any] = {
        "email": f"user-{uuid.uuid4().hex[:10]}@example.com",
        "password": "correct horse battery",
        "region": "ru",
        "timezone": "Europe/Samara",
        "consents": BASELINE_CONSENTS,
        "display_name": "Аня",
    }
    body.update(overrides)
    return {k: v for k, v in body.items() if v is not None}


async def test_register_without_a_name_is_a_validation_error(client: AsyncClient) -> None:
    resp = await client.post("/v1/auth/register", json=_register_body(display_name=None))
    assert resp.status_code == 422, resp.text
    assert resp.json()["error"]["code"] == "validation_error"


@pytest.mark.parametrize("name", ["", "  ", "A", "x" * 21, "An\x07na"])
async def test_register_rejects_a_bad_name(client: AsyncClient, name: str) -> None:
    resp = await client.post("/v1/auth/register", json=_register_body(display_name=name))
    assert resp.status_code == 422, resp.text
    assert resp.json()["error"]["code"] == "validation_error"


async def test_register_stores_the_trimmed_name_on_the_self_profile(
    client: AsyncClient,
) -> None:
    user = await register(client, display_name="  Мария  ")
    profiles = (await client.get("/v1/profiles", headers=user.headers)).json()["items"]
    assert [(p["kind"], p["display_name"]) for p in profiles] == [("self", "Мария")]


async def test_register_of_a_known_address_answers_alike_with_a_name(
    client: AsyncClient,
) -> None:
    """The name is checked before the address is looked up: no enumeration through it."""
    user = await register(client)
    again = await client.post(
        "/v1/auth/register", json=_register_body(email=user.email, display_name="Другое Имя")
    )
    fresh = await client.post("/v1/auth/register", json=_register_body())
    assert again.status_code == fresh.status_code == 202
    assert again.json() == fresh.json()
    nameless = await client.post(
        "/v1/auth/register", json=_register_body(email=user.email, display_name=None)
    )
    assert nameless.status_code == 422


# --- OAuth sign-up ------------------------------------------------------------------------------


@pytest.mark.usefixtures("oauth_on")
@pytest.mark.parametrize(
    "extra", [{"display_name": None}, {"display_name": "A"}, {"display_name": "x" * 21}]
)
async def test_oauth_sign_up_requires_a_person_name(
    client: AsyncClient, extra: dict[str, Any]
) -> None:
    ticket = ticket_of(await sign_in(client, email="named@example.com", verified=True))
    resp = await sign_up(client, ticket, consents=BASELINE_CONSENTS, **extra)
    assert resp.status_code == 422, resp.text
    assert resp.json()["error"]["code"] == "validation_error"


# --- renaming yourself: sync push ---------------------------------------------------------------


def _self_upsert(user: User, name: str, seconds: int = 1) -> dict[str, Any]:
    return {
        "entity": "profile",
        "op": "upsert",
        "id": user.self_profile_id,
        "data": {"kind": "self", "display_name": name, "timezone": "Europe/Samara"},
        "client_updated_at": (datetime.now(UTC) + timedelta(seconds=seconds)).isoformat(),
    }


async def _push(client: AsyncClient, user: User, mutations: list[dict[str, Any]]) -> list[Any]:
    resp = await client.post(
        "/v1/sync/push", json={"mutations": mutations}, headers=user.device("dev-1")
    )
    assert resp.status_code == 200, resp.text
    return [(r["status"], r["code"]) for r in resp.json()["results"]]


async def _self_name(client: AsyncClient, user: User) -> str:
    got = await client.get(f"/v1/profiles/{user.self_profile_id}", headers=user.headers)
    return str(got.json()["display_name"])


async def test_sync_renames_the_self_profile_within_the_rule(client: AsyncClient) -> None:
    user = await register(client)
    assert await _push(client, user, [_self_upsert(user, "  Иван  ")]) == [("applied", None)]
    assert await _self_name(client, user) == "Иван"


@pytest.mark.parametrize("name", ["A", "x" * 21, "Grandmother Alexandra Long"])
async def test_sync_rejects_a_self_rename_outside_the_rule(client: AsyncClient, name: str) -> None:
    user = await register(client, display_name="Аня")
    results = await _push(client, user, [_self_upsert(user, name)])
    assert results == [("rejected", "validation_error")]
    assert await _self_name(client, user) == "Аня"


async def test_sync_keeps_an_unchanged_legacy_self_name(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    """Accounts made before the rule may hold a longer or one-letter name: other edits pass."""
    user = await register(client)
    legacy = "Grandmother Alexandra Long"
    async with engine.begin() as conn:
        await conn.execute(
            text("UPDATE profiles SET display_name = :name WHERE id = :id"),
            {"name": legacy, "id": user.self_profile_id},
        )
    mutation = _self_upsert(user, legacy)
    mutation["data"]["timezone"] = "Asia/Omsk"
    assert await _push(client, user, [mutation]) == [("applied", None)]
    assert await _self_name(client, user) == legacy


async def test_sync_keeps_the_wide_rule_for_managed_profiles(client: AsyncClient) -> None:
    user = await register(client)
    pid = str(uuid.uuid4())
    mutation = {
        "entity": "profile",
        "op": "upsert",
        "id": pid,
        "data": {"kind": "managed", "display_name": "Z", "timezone": "UTC"},
        "client_updated_at": datetime.now(UTC).isoformat(),
    }
    assert await _push(client, user, [mutation]) == [("applied", None)]


# --- renaming yourself: REST --------------------------------------------------------------------


async def test_patch_of_the_self_profile_follows_the_rule(client: AsyncClient) -> None:
    user = await register(client, display_name="Аня")
    url = f"/v1/profiles/{user.self_profile_id}"
    bad = await client.patch(url, json={"display_name": "A"}, headers=user.headers)
    assert bad.status_code == 422, bad.text
    assert bad.json()["error"]["code"] == "validation_error"
    assert await _self_name(client, user) == "Аня"
    good = await client.patch(url, json={"display_name": " Анна "}, headers=user.headers)
    assert good.status_code == 200, good.text
    assert good.json()["display_name"] == "Анна"


async def test_patch_of_a_managed_profile_keeps_the_wide_rule(client: AsyncClient) -> None:
    user = await register(client)
    pid = str(uuid.uuid4())
    created = await client.post(
        "/v1/profiles",
        json={"id": pid, "display_name": "Kid", "timezone": "UTC"},
        headers=user.headers,
    )
    assert created.status_code == 201, created.text
    resp = await client.patch(
        f"/v1/profiles/{pid}", json={"display_name": "K"}, headers=user.headers
    )
    assert resp.status_code == 200, resp.text
