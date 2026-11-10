"""Purchases in the personal-data inventory, the logs and the soft limits (ADR 0018 6-7)."""

from __future__ import annotations

import uuid
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from app.config import Settings
from app.observability import (
    SENSITIVE_KEYS,
    SENTRY_SECRET_KEYS,
    redact_sensitive,
    scrub_sentry_event,
)
from app.services.export_archive import exported_columns
from app.services.personal_data import TABLE_CLASSIFICATION
from tests.grace_helpers import count, delete_and_erase
from tests.helpers import User, accept_invite, create_invite, link_accounts, register, token_of
from tests.payments_helpers import ORIGINAL_ID, Chain
from tests.purchase_helpers import account_token, buy, claim, signed
from tests.test_export_archive import archive_of, text_of

pytestmark = pytest.mark.usefixtures("payments_on")


def uid(user: User) -> uuid.UUID:
    return uuid.UUID(user.id)


# --- the inventory ------------------------------------------------------------------------------


def test_purchases_are_personal_data_exported_as_rows() -> None:
    info = TABLE_CLASSIFICATION["purchases"]
    assert (info.kind, info.owner_column, info.owner_ref) == ("personal", "user_id", "user")
    assert info.export == "rows"
    assert not info.export_exclude
    assert set(exported_columns("purchases")) == {
        "id",
        "user_id",
        "store",
        "product_id",
        "original_transaction_id",
        "environment",
        "purchased_at",
        "verified_at",
        "revoked_at",
    }


def test_proofs_and_the_account_token_are_redacted_log_keys_and_scrubbed_tracker_keys() -> None:
    for key in ("signed_transaction", "purchase_token", "app_account_token"):
        assert key in SENSITIVE_KEYS
        assert key in SENTRY_SECRET_KEYS
        assert redact_sensitive(None, "info", {"event": "x", key: "SYNTHETIC-PROOF"})[key] == (
            "[redacted]"
        )


def test_the_error_tracker_loses_a_proof_in_a_body_and_in_frame_variables() -> None:
    event: dict[str, Any] = {
        "request": {"data": {"signed_transaction": "BODYPROOF", "store": "app_store"}},
        "extra": {"purchase_token": "EXTRAPROOF"},
        "exception": {
            "values": [{"stacktrace": {"frames": [{"vars": {"signed_transaction": "FRAMEPROOF"}}]}}]
        },
    }
    scrubbed = scrub_sentry_event(event, {})
    assert scrubbed is not None
    dumped = str(scrubbed)
    for secret in ("BODYPROOF", "EXTRAPROOF", "FRAMEPROOF"):
        assert secret not in dumped
    assert scrubbed["request"]["data"]["store"] == "app_store"


# --- erasure and export -------------------------------------------------------------------------


async def test_erasing_an_account_deletes_its_purchases_and_leaves_the_others(
    client: AsyncClient, apple_chain: Chain, engine: AsyncEngine
) -> None:
    gone, kept = await register(client), await register(client)
    assert (await buy(client, apple_chain, gone)).status_code == 201
    assert (await buy(client, apple_chain, kept, original_id="2000000555555555")).status_code == 201

    await delete_and_erase(client, gone)

    assert await count(engine, "purchases", "user_id = :u", u=uid(gone)) == 0
    assert await count(engine, "purchases", "user_id = :u", u=uid(kept)) == 1
    assert await count(engine, "entitlements", "user_id = :u", u=uid(gone)) == 0
    assert await count(engine, "entitlements", "user_id = :u", u=uid(kept)) == 2


async def test_erasure_frees_the_purchase_for_a_new_claim(
    client: AsyncClient, apple_chain: Chain
) -> None:
    gone, other = await register(client), await register(client)
    assert (await buy(client, apple_chain, gone)).status_code == 201
    await delete_and_erase(client, gone)
    assert (await buy(client, apple_chain, other)).status_code == 201


async def test_the_export_holds_the_accounts_purchases_and_never_a_proof(
    client: AsyncClient, apple_chain: Chain
) -> None:
    me, other = await register(client), await register(client)
    proof = signed(apple_chain, await account_token(client, me))
    assert (await claim(client, me, proof)).status_code == 201
    assert (
        await buy(client, apple_chain, other, original_id="2000000444444444")
    ).status_code == 201

    _, members = await archive_of(client, me)
    dumped = text_of(members)

    [row] = members["tables/purchases.json"]
    assert row["user_id"] == me.id
    assert row["original_transaction_id"] == ORIGINAL_ID
    assert row["store"] == "app_store"
    assert other.id not in dumped
    assert "2000000444444444" not in dumped
    assert proof not in dumped
    assert proof.split(".")[1] not in dumped
    assert members["manifest.json"]["tables"]["purchases"] == 1


# --- logs ---------------------------------------------------------------------------------------


async def test_a_proof_never_reaches_the_logs_on_any_outcome(
    client: AsyncClient, apple_chain: Chain, capsys: pytest.CaptureFixture[str]
) -> None:
    first, second = await register(client), await register(client)
    first_token = await account_token(client, first)
    good = signed(apple_chain, first_token)
    bad = signed(apple_chain, first_token, bundleId="synthetic-secret-bundle")
    stolen = signed(apple_chain, first_token)
    await claim(client, first, good)  # 201
    await claim(client, first, good)  # a replay
    await claim(client, first, bad)  # 400
    await claim(client, second, stolen)  # 400, not the owner
    await claim(client, second, "synthetic-garbage-proof")  # 400
    await claim(client, second, "synthetic-token", store="rustore")  # 503
    logged = capsys.readouterr()
    output = logged.out + logged.err
    assert "http_request" in output  # the access log ran
    assert "purchase_rejected" in output  # and the rejection reason is logged
    for secret in (
        good,
        good.split(".")[1],
        bad,
        "synthetic-secret-bundle",
        "synthetic-garbage-proof",
        "synthetic-token",
        ORIGINAL_ID,
        str(first_token),
    ):
        assert secret not in output


# --- soft limits (ADR 0018 section 7) ------------------------------------------------------------


@pytest.fixture
def limits_on(monkeypatch: pytest.MonkeyPatch, settings: Settings) -> Settings:
    monkeypatch.setattr(settings, "feature_soft_limits", True)
    return settings


async def fill_relatives(client: AsyncClient, owner: User, limit: int) -> None:
    for _ in range(limit):
        await link_accounts(client, owner, await register(client))


async def test_without_the_entitlement_the_relatives_limit_holds(
    client: AsyncClient, limits_on: Settings
) -> None:
    owner = await register(client)
    await fill_relatives(client, owner, limits_on.soft_limit_relatives)
    resp = await accept_invite(
        client, await register(client), token_of(await create_invite(client, owner))
    )
    assert resp.status_code == 409
    assert resp.json()["error"]["code"] == "relatives_limit_reached"


async def test_a_purchase_lifts_the_relatives_limit(
    client: AsyncClient, apple_chain: Chain, limits_on: Settings
) -> None:
    owner = await register(client)
    await fill_relatives(client, owner, limits_on.soft_limit_relatives)
    assert (await buy(client, apple_chain, owner)).status_code == 201
    for _ in range(2):
        resp = await accept_invite(
            client, await register(client), token_of(await create_invite(client, owner))
        )
        assert resp.status_code == 201


async def test_a_revoked_or_expired_entitlement_no_longer_lifts_it(
    client: AsyncClient, apple_chain: Chain, limits_on: Settings, engine: AsyncEngine
) -> None:
    owner = await register(client)
    assert (await buy(client, apple_chain, owner)).status_code == 201
    await fill_relatives(client, owner, limits_on.soft_limit_relatives)
    async with engine.begin() as conn:
        await conn.execute(
            text("UPDATE entitlements SET revoked_at = now() WHERE user_id = :u"), {"u": uid(owner)}
        )
    resp = await accept_invite(
        client, await register(client), token_of(await create_invite(client, owner))
    )
    assert resp.status_code == 409


async def test_a_relatives_own_purchase_does_not_lift_the_owners_limit(
    client: AsyncClient, apple_chain: Chain, limits_on: Settings
) -> None:
    owner, buyer = await register(client), await register(client)
    await fill_relatives(client, owner, limits_on.soft_limit_relatives - 1)
    await link_accounts(client, owner, buyer)
    assert (await buy(client, apple_chain, buyer)).status_code == 201
    resp = await accept_invite(
        client, await register(client), token_of(await create_invite(client, owner))
    )
    assert resp.status_code == 409  # entitlements are per account, never inherited
