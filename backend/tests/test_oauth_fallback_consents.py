"""The e-mail fallback (ADR 0017 section 5): consents chosen by whoever started it do not stand
for the owner of the mailbox who verified the address without the pending token."""

from __future__ import annotations

from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.grace_helpers import scalar
from tests.helpers import last_code
from tests.oauth_helpers import CONSENTS, bearer, sign_in, sign_up, ticket_of

pytestmark = pytest.mark.usefixtures("oauth_on")

TYPED = "typed@example.com"
BASELINE = ["health_data", "terms", "privacy"]


async def started_with_consents(client: AsyncClient) -> str:
    """Start the fallback with consents, a name and a locale; returns the pending token."""
    ticket = ticket_of(await sign_in(client, email="vk@example.com", verified=False))
    resp = await sign_up(
        client,
        ticket,
        email=TYPED,
        consents=CONSENTS,
        locale="ru",
        display_name="Chosen By Starter",
    )
    assert resp.status_code == 202, resp.text
    return str(resp.json()["pending_token"])


async def verify(client: AsyncClient, token: str | None) -> dict[str, Any]:
    body = {"email": TYPED, "code": last_code(client, TYPED)}
    if token is not None:
        body["pending_token"] = token
    resp = await client.post("/v1/auth/verify-email", json=body)
    assert resp.status_code == 200, resp.text
    return dict(resp.json())


async def consents_of(client: AsyncClient, tokens: dict[str, Any]) -> dict[str, Any]:
    resp = await client.get("/v1/me/consents", headers=bearer(tokens))
    assert resp.status_code == 200, resp.text
    return dict(resp.json())


async def test_with_the_token_the_consents_stand(client: AsyncClient) -> None:
    tokens = await verify(client, await started_with_consents(client))
    assert (await consents_of(client, tokens))["missing"] == []


@pytest.mark.parametrize("token", [None, "wrong-token-0123456789abcdef"])
async def test_without_the_token_the_starters_consents_are_withdrawn(
    client: AsyncClient, engine: AsyncEngine, token: str | None
) -> None:
    await started_with_consents(client)
    tokens = await verify(client, token)
    overview = await consents_of(client, tokens)
    assert overview["missing"] == BASELINE  # the re-consent gate runs
    assert len(overview["records"]) == 3
    assert all(r["withdrawn_at"] is not None for r in overview["records"])
    assert await scalar(engine, "SELECT count(*) FROM consents WHERE withdrawn_at IS NULL") == 0
    # Name, locale and time zone chosen then are harmless and stay.
    me = (await client.get("/v1/me", headers=bearer(tokens))).json()
    assert me["locale"] == "ru"
    assert await scalar(engine, "SELECT timezone FROM profiles LIMIT 1") == "Europe/Samara"


async def test_the_owner_can_consent_afresh_after_the_withdrawal(client: AsyncClient) -> None:
    await started_with_consents(client)
    tokens = await verify(client, None)
    for kind in BASELINE:
        resp = await client.post(
            "/v1/me/consents", json={"kind": kind, "version": 1}, headers=bearer(tokens)
        )
        assert resp.status_code in (200, 201), resp.text
    assert (await consents_of(client, tokens))["missing"] == []
