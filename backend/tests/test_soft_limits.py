"""Soft limits behind FEATURE_SOFT_LIMITS (TZ §1, ADR 0005 §6) and GET /v1/me/features."""

from __future__ import annotations

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from tests.helpers import (
    accept_invite,
    create_invite,
    create_managed_profile,
    link_accounts,
    register,
    token_of,
)


@pytest.fixture
def limits_on(monkeypatch: pytest.MonkeyPatch, settings: Settings) -> Settings:
    monkeypatch.setattr(settings, "feature_soft_limits", True)
    return settings


async def test_features_are_off_by_default(client: AsyncClient) -> None:
    user = await register(client)
    resp = await client.get("/v1/me/features", headers=user.headers)
    assert resp.status_code == 200
    assert resp.json() == {
        "soft_limits_enabled": False,
        "relatives_limit": None,
        "pdf_reports_limit": None,
    }


async def test_features_tell_the_app_what_to_gate(client: AsyncClient, limits_on: Settings) -> None:
    user = await register(client)
    resp = await client.get("/v1/me/features", headers=user.headers)
    assert resp.json() == {
        "soft_limits_enabled": True,
        "relatives_limit": 3,
        "pdf_reports_limit": limits_on.soft_limit_pdf_reports,
    }


async def test_features_require_authentication(client: AsyncClient) -> None:
    assert (await client.get("/v1/me/features")).status_code == 401


async def test_nothing_is_limited_while_the_flag_is_off(client: AsyncClient) -> None:
    owner = await register(client)
    for _ in range(5):
        await link_accounts(client, owner, await register(client))
    assert len((await client.get("/v1/grants", headers=owner.headers)).json()["outgoing"]) == 5


async def test_accepting_beyond_the_relatives_limit_fails(
    client: AsyncClient, limits_on: Settings, engine: AsyncEngine
) -> None:
    owner = await register(client)
    ward = await create_managed_profile(client, owner)
    members = [await register(client) for _ in range(3)]
    await link_accounts(client, owner, members[0])
    await link_accounts(client, owner, members[1])
    await link_accounts(client, owner, members[2], "guardian", ward)  # counted across profiles

    latecomer = await register(client)
    invite = await create_invite(client, owner)
    resp = await accept_invite(client, latecomer, token_of(invite))
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "relatives_limit_reached"
    async with engine.connect() as conn:
        consumed = (
            await conn.execute(
                text("SELECT consumed_at FROM invites WHERE id = :i"), {"i": invite["id"]}
            )
        ).scalar_one()
    assert consumed is None  # the link survives until the owner frees a slot

    grants = (await client.get("/v1/grants", headers=owner.headers)).json()["outgoing"]
    await client.delete(f"/v1/grants/{grants[0]['id']}", headers=owner.headers)
    assert (await accept_invite(client, latecomer, token_of(invite))).status_code == 201


async def test_a_replay_is_not_blocked_by_the_limit(
    client: AsyncClient, limits_on: Settings
) -> None:
    owner = await register(client)
    first = await register(client)
    token = token_of(await create_invite(client, owner))
    assert (await accept_invite(client, first, token)).status_code == 201
    for _ in range(2):
        await link_accounts(client, owner, await register(client))
    assert (
        await accept_invite(
            client, await register(client), token_of(await create_invite(client, owner))
        )
    ).status_code == 409
    replay = await accept_invite(client, first, token)
    assert replay.status_code == 200


async def test_the_limit_counts_the_owners_relatives_not_the_accepters(
    client: AsyncClient, limits_on: Settings
) -> None:
    busy, quiet, relative = [await register(client) for _ in range(3)]
    for _ in range(3):
        await link_accounts(client, busy, await register(client))
    # Holding grants as a relative does not use up the relative's own allowance,
    # and a quiet owner is unaffected by the busy one.
    await link_accounts(client, quiet, relative)
    assert (await link_accounts(client, relative, await register(client)))["role"] == "viewer"
