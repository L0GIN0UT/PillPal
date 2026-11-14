"""Helpers for private notes about relatives (ADR 0020 section 4)."""

from __future__ import annotations

from typing import Any

from httpx import AsyncClient

from tests.helpers import User


async def put_note(client: AsyncClient, user: User, profile_id: str, note: Any) -> Any:
    return await client.put(
        f"/v1/relative-notes/{profile_id}", json={"note": note}, headers=user.headers
    )


async def delete_note(client: AsyncClient, user: User, profile_id: str) -> Any:
    return await client.delete(f"/v1/relative-notes/{profile_id}", headers=user.headers)


async def notes_of(client: AsyncClient, user: User) -> dict[str, str]:
    """``profile_id -> note`` from the caller's ``GET /v1/grants``."""
    resp = await client.get("/v1/grants", headers=user.headers)
    assert resp.status_code == 200, resp.text
    return {row["profile_id"]: row["note"] for row in resp.json()["notes"]}
