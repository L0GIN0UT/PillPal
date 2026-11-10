"""Helpers of the purchase suites (ADR 0018 section 6): signed transactions and the claim call."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime
from typing import Any

from httpx import AsyncClient, Response

from tests.helpers import User
from tests.payments_helpers import Chain, sign, transaction

URL = "/v1/me/purchases"
ENTITLEMENTS_URL = "/v1/me/entitlements"
INVALID = {"error": {"code": "invalid_purchase", "message": "This purchase cannot be accepted"}}


async def account_token(client: AsyncClient, user: User) -> uuid.UUID:
    resp = await client.get(ENTITLEMENTS_URL, headers=user.headers)
    assert resp.status_code == 200, resp.text
    return uuid.UUID(resp.json()["app_account_token"])


def signed(chain: Chain, token: uuid.UUID | str | None, **overrides: Any) -> str:
    """A transaction signed now by the synthetic chain; see ``tests.payments_helpers``."""
    return sign(chain, transaction(token, at=datetime.now(UTC), **overrides))


async def claim(client: AsyncClient, user: User, proof: str, store: str = "app_store") -> Response:
    field = "signed_transaction" if store == "app_store" else "purchase_token"
    return await client.post(URL, json={"store": store, field: proof}, headers=user.headers)


async def buy(client: AsyncClient, chain: Chain, user: User, **overrides: Any) -> Response:
    """The account buys the remove-ads product: its own token, then the claim."""
    return await claim(client, user, signed(chain, await account_token(client, user), **overrides))
