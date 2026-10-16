"""Profiles: self profile, managed profile CRUD, ownership."""

from __future__ import annotations

import uuid

import pytest
from httpx import AsyncClient

from tests.helpers import create_medication, register


async def test_create_and_list_managed_profile(client: AsyncClient) -> None:
    user = await register(client)
    pid = str(uuid.uuid4())
    resp = await client.post(
        "/v1/profiles",
        json={"id": pid, "display_name": "Grandma", "timezone": "Asia/Yekaterinburg"},
        headers=user.headers,
    )
    assert resp.status_code == 201, resp.text
    body = resp.json()
    assert body["id"] == pid
    assert body["kind"] == "managed"
    assert body["version"] == 1

    items = (await client.get("/v1/profiles", headers=user.headers)).json()["items"]
    assert [p["kind"] for p in items] == ["self", "managed"]
    got = await client.get(f"/v1/profiles/{pid}", headers=user.headers)
    assert got.json()["display_name"] == "Grandma"


@pytest.mark.parametrize(
    "payload",
    [
        {"display_name": "X", "timezone": "Mars/Base"},
        {"display_name": "", "timezone": "UTC"},
        {"display_name": "x" * 101, "timezone": "UTC"},
        {"display_name": "X", "timezone": "UTC", "kind": "self"},
        {"display_name": "X", "timezone": "UTC", "owner_user_id": str(uuid.uuid4())},
    ],
)
async def test_create_profile_validation(client: AsyncClient, payload: dict[str, str]) -> None:
    user = await register(client)
    resp = await client.post(
        "/v1/profiles", json={"id": str(uuid.uuid4()), **payload}, headers=user.headers
    )
    assert resp.status_code == 422
    assert resp.json()["error"]["code"] == "validation_error"


async def test_duplicate_profile_id_is_conflict(client: AsyncClient) -> None:
    user = await register(client)
    other = await register(client)
    body = {"id": str(uuid.uuid4()), "display_name": "Kid", "timezone": "UTC"}
    assert (await client.post("/v1/profiles", json=body, headers=user.headers)).status_code == 201
    again = await client.post("/v1/profiles", json=body, headers=user.headers)
    assert again.status_code == 409
    assert again.json()["error"]["code"] == "already_exists"
    # The same id from another account is equally a conflict, revealing nothing else.
    assert (await client.post("/v1/profiles", json=body, headers=other.headers)).status_code == 409


async def test_update_profile_bumps_version(client: AsyncClient) -> None:
    user = await register(client)
    url = f"/v1/profiles/{user.self_profile_id}"
    resp = await client.patch(url, json={"timezone": "Europe/Berlin"}, headers=user.headers)
    assert resp.status_code == 200
    assert resp.json()["timezone"] == "Europe/Berlin"
    assert resp.json()["version"] == 2
    # Empty patch is a no-op.
    same = await client.patch(url, json={}, headers=user.headers)
    assert same.json()["version"] == 2
    bad = await client.patch(url, json={"kind": "managed"}, headers=user.headers)
    assert bad.status_code == 422


async def test_self_profile_cannot_be_deleted(client: AsyncClient) -> None:
    user = await register(client)
    resp = await client.delete(f"/v1/profiles/{user.self_profile_id}", headers=user.headers)
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "self_profile_protected"


async def test_delete_managed_profile_tombstones_children(client: AsyncClient) -> None:
    user = await register(client)
    pid = str(uuid.uuid4())
    await client.post(
        "/v1/profiles",
        json={"id": pid, "display_name": "Cat", "timezone": "UTC"},
        headers=user.headers,
    )
    med = await create_medication(client, user, profile_id=pid)
    assert (await client.delete(f"/v1/profiles/{pid}", headers=user.headers)).status_code == 204
    assert (await client.get(f"/v1/profiles/{pid}", headers=user.headers)).status_code == 404
    assert (
        await client.get(f"/v1/medications/{med['id']}", headers=user.headers)
    ).status_code == 404
    # Idempotent delete.
    assert (await client.delete(f"/v1/profiles/{pid}", headers=user.headers)).status_code == 204
    # Deleted profile no longer accepts medications.
    resp = await client.get(f"/v1/profiles/{pid}/medications", headers=user.headers)
    assert resp.status_code == 404


async def test_profiles_are_owner_scoped(client: AsyncClient) -> None:
    alice = await register(client)
    bob = await register(client)
    url = f"/v1/profiles/{alice.self_profile_id}"
    for method, kwargs in [
        ("GET", {}),
        ("PATCH", {"json": {"display_name": "pwned"}}),
        ("DELETE", {}),
    ]:
        resp = await client.request(method, url, headers=bob.headers, **kwargs)  # type: ignore[arg-type]
        assert resp.status_code == 404, method
        assert resp.json()["error"]["code"] == "not_found"
    bob_list = (await client.get("/v1/profiles", headers=bob.headers)).json()["items"]
    assert alice.self_profile_id not in {p["id"] for p in bob_list}
    alice_profile = (await client.get(url, headers=alice.headers)).json()
    assert alice_profile["display_name"] != "pwned"


async def test_requires_authentication(client: AsyncClient) -> None:
    assert (await client.get("/v1/profiles")).status_code == 401
