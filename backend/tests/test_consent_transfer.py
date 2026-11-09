"""Consent follows the person who gave it (ADR 0014 §2): hand-over and archiving reset it."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.grace_helpers import pending_login, request_deletion, restore, run_erase_job
from tests.helpers import User, create_managed_profile, create_medication, link_accounts, register
from tests.sync_helpers import sync_all
from tests.test_medication_refs import GTIN, PRODUCT

pytestmark = pytest.mark.usefixtures("contributions_on")

OPTED_IN: dict[str, Any] = {
    "gtin": GTIN,
    "catalog_product_id": PRODUCT,
    "gtin_link_shared": True,
    "gtin_link_consent_version": 1,
}


async def shared_row(engine: AsyncEngine, med_id: str) -> Any:
    async with engine.connect() as conn:
        found = await conn.execute(
            text(
                "SELECT gtin_link_shared, gtin_link_consent_version, gtin_link_consented_at, "
                "version FROM medications WHERE id = :i"
            ),
            {"i": med_id},
        )
        return found.one()


async def ward_with_consent(client: AsyncClient) -> tuple[User, User, str, str]:
    owner, heir = await register(client), await register(client)
    ward = await create_managed_profile(client, owner)
    await link_accounts(client, owner, heir, "guardian", ward)
    med = await create_medication(client, owner, profile_id=ward, **OPTED_IN)
    assert med["gtin_link_shared"] is True
    return owner, heir, ward, med["id"]


async def test_the_hand_over_at_erasure_resets_the_consent_and_journals_it(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, heir, ward, med_id = await ward_with_consent(client)
    before = await sync_all(client, heir, {ward: 0}, device="heir-dev")
    version = before.by_id(med_id)["data"]["version"]
    assert (await request_deletion(client, owner)).status_code == 204
    report = await run_erase_job(client, datetime.now(UTC) + timedelta(days=31))
    assert report.erased == 1
    row = await shared_row(engine, med_id)
    assert (row.gtin_link_shared, row.gtin_link_consent_version, row.gtin_link_consented_at) == (
        False,
        None,
        None,
    )
    after = await sync_all(client, heir, before.cursors, device="heir-dev")
    data = after.by_id(med_id)["data"]
    assert data["gtin_link_shared"] is False
    assert data["version"] > version
    assert data["gtin"] == GTIN  # the link itself stays, only the consent goes


async def test_archiving_a_pending_deletion_account_resets_the_consent(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner, _heir, _ward, med_id = await ward_with_consent(client)
    assert (await request_deletion(client, owner)).status_code == 204
    row = await shared_row(engine, med_id)
    assert row.gtin_link_shared is False
    assert row.gtin_link_consented_at is None
    # A restore does not bring a consent back: the owner has to confirm it again.
    ticket, code = await pending_login(client, owner)
    assert (await restore(client, ticket, code)).status_code == 200
    assert (await shared_row(engine, med_id)).gtin_link_shared is False


async def test_an_own_profile_keeps_its_consent_while_deletion_is_pending(
    client: AsyncClient, engine: AsyncEngine
) -> None:
    owner = await register(client)
    own = await create_medication(client, owner, **OPTED_IN)
    ward = await create_managed_profile(client, owner)
    other = await create_medication(client, owner, profile_id=ward, **OPTED_IN)
    assert (await request_deletion(client, owner)).status_code == 204
    # Only archived managed profiles are reset; the account's own data is excluded from the
    # aggregate by its pending state (ADR 0014 §3), and erased with it.
    assert (await shared_row(engine, other["id"])).gtin_link_shared is False
    assert (await shared_row(engine, own["id"])).gtin_link_shared is True
