"""Helpers for the scoped sync suites (ADR 0006): pull to completion, push, privacy edits."""

from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from typing import Any

from httpx import AsyncClient

from tests.helpers import User, daily_rule
from tests.test_sync import med_data, mut, ts


async def scoped_pull(
    client: AsyncClient,
    user: User,
    cursors: dict[str, int],
    *,
    device: str = "dev-1",
    limit: int = 100,
    expect: int = 200,
) -> Any:
    resp = await client.post(
        "/v1/sync/pull",
        json={"cursors": cursors, "limit": limit},
        headers=user.device(device),
    )
    assert resp.status_code == expect, resp.text
    return resp.json()


@dataclass
class Synced:
    """What a client holds after pulling every scope to completion."""

    changes: list[dict[str, Any]] = field(default_factory=list)
    scopes: dict[str, dict[str, Any]] = field(default_factory=dict)
    cursors: dict[str, int] = field(default_factory=dict)
    revoked: list[str] = field(default_factory=list)
    pages: int = 0

    def of(self, entity: str, op: str | None = None) -> list[dict[str, Any]]:
        return [c for c in self.changes if c["entity"] == entity and op in (None, c["op"])]

    def ids(self, entity: str, op: str | None = None) -> set[str]:
        return {c["id"] for c in self.of(entity, op)}

    def by_id(self, entity_id: str) -> dict[str, Any]:
        matches = [c for c in self.changes if c["id"] == entity_id]
        assert matches, f"{entity_id} was not delivered"
        return matches[-1]


async def sync_all(
    client: AsyncClient,
    user: User,
    cursors: dict[str, int] | None = None,
    *,
    device: str = "dev-1",
    limit: int = 100,
) -> Synced:
    """Pull like the app: add new scopes from ``scopes`` at cursor 0, loop while ``has_more``."""
    out = Synced(cursors=dict(cursors if cursors is not None else {user.self_profile_id: 0}))
    while True:
        page = await scoped_pull(client, user, out.cursors, device=device, limit=limit)
        out.pages += 1
        out.changes += page["changes"]
        out.revoked += page["revoked"]
        out.scopes = {s["profile_id"]: s for s in page["scopes"]}
        for pid in page["revoked"]:
            out.cursors.pop(pid, None)
        for scope in page["scopes"]:
            if scope["cursor"] is not None:
                out.cursors[scope["profile_id"]] = scope["cursor"]
        new = [pid for pid in out.scopes if pid not in out.cursors]
        for pid in new:
            out.cursors[pid] = 0
        if not page["has_more"] and not new:
            return out


async def push_as(
    client: AsyncClient,
    user: User,
    mutations: list[dict[str, Any]],
    device: str = "dev-1",
) -> list[dict[str, Any]]:
    resp = await client.post(
        "/v1/sync/push", json={"mutations": mutations}, headers=user.device(device)
    )
    assert resp.status_code == 200, resp.text
    results: list[dict[str, Any]] = resp.json()["results"]
    assert [r["id"] for r in results] == [m["id"] for m in mutations]
    return results


def outcome(result: dict[str, Any]) -> tuple[str, str | None]:
    return result["status"], result["code"]


async def make_medication(
    client: AsyncClient, owner: User, profile_id: str, privacy: str = "shared", **extra: Any
) -> str:
    """A medication created by its owner through REST; returns its id."""
    mid = str(uuid.uuid4())
    resp = await client.post(
        f"/v1/profiles/{profile_id}/medications",
        json={"id": mid, "name": "Synthetic Tablet", "notes": "private note", "privacy": privacy}
        | extra,
        headers=owner.headers,
    )
    assert resp.status_code == 201, resp.text
    return mid


async def make_schedule(client: AsyncClient, owner: User, medication_id: str) -> str:
    sid = str(uuid.uuid4())
    resp = await client.post(
        f"/v1/medications/{medication_id}/schedules",
        json={"id": sid, "rule": daily_rule(("08:00", "20:00"))},
        headers=owner.headers,
    )
    assert resp.status_code == 201, resp.text
    return sid


async def make_event(client: AsyncClient, owner: User, medication_id: str, **extra: Any) -> str:
    eid = str(uuid.uuid4())
    body = {
        "id": eid,
        "medication_id": medication_id,
        "type": "taken",
        "at": ts(),
        "note": "felt dizzy",
    } | extra
    resp = await client.post("/v1/dose-events", json=body, headers=owner.device("owner-dev"))
    assert resp.status_code == 201, resp.text
    return eid


async def set_privacy(client: AsyncClient, owner: User, medication_id: str, privacy: str) -> None:
    resp = await client.patch(
        f"/v1/medications/{medication_id}", json={"privacy": privacy}, headers=owner.headers
    )
    assert resp.status_code == 200, resp.text


async def revoke(client: AsyncClient, owner: User, grant: dict[str, Any]) -> None:
    resp = await client.delete(f"/v1/grants/{grant['id']}", headers=owner.headers)
    assert resp.status_code == 204, resp.text


def editor_med(profile_id: str, **overrides: Any) -> dict[str, Any]:
    return med_data(profile_id, name="Edited by relative", **overrides)


__all__ = [
    "Synced",
    "editor_med",
    "make_event",
    "make_medication",
    "make_schedule",
    "mut",
    "outcome",
    "push_as",
    "revoke",
    "scoped_pull",
    "set_privacy",
    "sync_all",
    "ts",
]
