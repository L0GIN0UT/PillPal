"""The aggregate of opted-in links (ADR 0014 section 3): who is counted, who never is."""

from __future__ import annotations

import dataclasses
from datetime import UTC, datetime

import pytest
from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker

from app.config import Settings
from app.services.catalog_contributions import Confirmation, aggregate_confirmations
from tests.catalog_helpers import (
    GTIN,
    OTHER_GTIN,
    OTHER_PRODUCT,
    PRODUCT,
    RESTRICTED_GTIN,
    age_account,
    contributor,
    link,
)
from tests.grace_helpers import request_deletion
from tests.helpers import create_managed_profile, register

pytestmark = pytest.mark.usefixtures("contributions_on")


async def run(maker: async_sessionmaker[AsyncSession], settings: Settings) -> list[Confirmation]:
    return await aggregate_confirmations(maker, settings, datetime.now(UTC))


async def test_distinct_owners_are_counted_and_only_gtin_product_and_count_are_sent(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
) -> None:
    for _ in range(3):
        await contributor(client, engine)
    found = await run(maker, settings)
    assert found == [Confirmation(GTIN, PRODUCT, 3)]
    assert {f.name for f in dataclasses.fields(found[0])} == {"gtin", "product_id", "count"}


async def test_two_profiles_of_one_owner_count_once(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
) -> None:
    owner = await contributor(client, engine)  # own profile
    ward = await create_managed_profile(client, owner)
    await link(client, owner, profile_id=ward)  # a managed profile of the same owner
    assert await run(maker, settings) == []  # one person: never sent
    await contributor(client, engine)
    assert await run(maker, settings) == [Confirmation(GTIN, PRODUCT, 2)]


async def test_counts_below_the_reporting_minimum_are_never_sent(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
) -> None:
    await contributor(client, engine)
    await contributor(client, engine, gtin=OTHER_GTIN)
    await contributor(client, engine, gtin=OTHER_GTIN)
    assert await run(maker, settings) == [Confirmation(OTHER_GTIN, PRODUCT, 2)]


async def test_pairs_are_counted_separately(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
) -> None:
    for _ in range(2):
        await contributor(client, engine)
        await contributor(client, engine, product=OTHER_PRODUCT)
    got = await run(maker, settings)
    assert sorted((c.gtin, str(c.product_id), c.count) for c in got) == sorted(
        [(GTIN, str(PRODUCT), 2), (GTIN, str(OTHER_PRODUCT), 2)]
    )


async def test_accounts_younger_than_the_minimum_age_do_not_count(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
) -> None:
    await contributor(client, engine)
    await contributor(client, engine)
    young = await contributor(client, engine)
    await age_account(engine, young, settings.catalog_contribution_min_account_age_days - 1)
    assert await run(maker, settings) == [Confirmation(GTIN, PRODUCT, 2)]
    await age_account(engine, young, settings.catalog_contribution_min_account_age_days + 1)
    assert await run(maker, settings) == [Confirmation(GTIN, PRODUCT, 3)]


async def test_an_account_pending_deletion_stops_counting_although_its_consent_stays(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
) -> None:
    await contributor(client, engine)
    await contributor(client, engine)
    leaving = await contributor(client, engine)
    assert (await request_deletion(client, leaving)).status_code == 204
    async with engine.connect() as conn:  # an own profile keeps its consent in the grace period
        shared = (
            await conn.execute(
                text(
                    "SELECT gtin_link_shared FROM medications m JOIN profiles p "
                    "ON p.id = m.profile_id WHERE p.owner_user_id = :u"
                ),
                {"u": leaving.id},
            )
        ).scalar_one()
    assert shared is True
    assert await run(maker, settings) == [Confirmation(GTIN, PRODUCT, 2)]


async def test_opted_out_tombstoned_and_archived_links_do_not_count(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
) -> None:
    await contributor(client, engine)
    await contributor(client, engine)
    out = await register(client)
    await age_account(engine, out, 30)
    await link(client, out, shared=False)  # linked, never opted in
    gone = await register(client)
    await age_account(engine, gone, 30)
    med = await link(client, gone)
    delete = await client.delete(f"/v1/medications/{med['id']}", headers=gone.headers)
    assert delete.status_code == 204
    owner = await register(client)
    await age_account(engine, owner, 30)
    ward = await create_managed_profile(client, owner)
    await link(client, owner, profile_id=ward)
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "UPDATE profiles SET archived_at = now(), archive_reason = "
                "'owner_pending_deletion' WHERE id = :i"
            ),
            {"i": ward},
        )
    assert await run(maker, settings) == [Confirmation(GTIN, PRODUCT, 2)]


async def test_a_deleted_managed_profile_does_not_count(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
) -> None:
    await contributor(client, engine)
    await contributor(client, engine)
    owner = await register(client)
    await age_account(engine, owner, 30)
    ward = await create_managed_profile(client, owner)
    await link(client, owner, profile_id=ward)
    assert len(await run(maker, settings)) == 1
    assert (await run(maker, settings))[0].count == 3
    gone = await client.delete(f"/v1/profiles/{ward}", headers=owner.headers)
    assert gone.status_code == 204
    assert await run(maker, settings) == [Confirmation(GTIN, PRODUCT, 2)]


async def test_restricted_numbers_are_never_sent_even_if_stored_with_consent(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
) -> None:
    users = [await contributor(client, engine) for _ in range(3)]
    async with engine.begin() as conn:  # a legacy or tampered row: the filter is defence in depth
        await conn.execute(
            text("UPDATE medications SET gtin = :g WHERE profile_id = ANY(:p)"),
            {"g": RESTRICTED_GTIN, "p": [u.self_profile_id for u in users]},
        )
    assert await run(maker, settings) == []


async def test_a_consent_given_for_a_retired_text_version_is_not_counted(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
) -> None:
    users = [await contributor(client, engine) for _ in range(3)]
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "UPDATE medications SET gtin_link_consent_version = 99 WHERE profile_id = ANY(:p)"
            ),
            {"p": [users[0].self_profile_id, users[1].self_profile_id]},
        )
    assert await run(maker, settings) == []  # only one consent left: below the minimum


async def test_erasure_of_an_account_lowers_the_next_snapshot(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
) -> None:
    from tests.grace_helpers import run_erase_job

    await contributor(client, engine)
    await contributor(client, engine)
    leaving = await contributor(client, engine)
    assert len(await run(maker, settings)) == 1
    assert (await request_deletion(client, leaving)).status_code == 204
    async with engine.begin() as conn:
        await conn.execute(
            text(
                "UPDATE users SET erase_after = now() - interval '1 hour', "
                "deletion_requested_at = now() - interval '2 hour' WHERE id = :i"
            ),
            {"i": leaving.id},
        )
    await run_erase_job(client)
    assert await run(maker, settings) == [Confirmation(GTIN, PRODUCT, 2)]


async def test_an_unverified_account_does_not_count(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
) -> None:
    await contributor(client, engine)
    await contributor(client, engine)
    unverified = await contributor(client, engine)
    async with engine.begin() as conn:
        await conn.execute(
            text("UPDATE users SET email_verified_at = NULL WHERE id = :i"), {"i": unverified.id}
        )
    assert await run(maker, settings) == [Confirmation(GTIN, PRODUCT, 2)]


async def test_a_live_medication_of_a_tombstoned_profile_does_not_count(
    client: AsyncClient,
    engine: AsyncEngine,
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
) -> None:
    await contributor(client, engine)
    await contributor(client, engine)
    owner = await register(client)
    await age_account(engine, owner, 30)
    ward = await create_managed_profile(client, owner)
    await link(client, owner, profile_id=ward)
    async with engine.begin() as conn:  # a row the sync cascade has not reached (defence in depth)
        await conn.execute(
            text("UPDATE profiles SET deleted_at = now(), display_name = NULL WHERE id = :i"),
            {"i": ward},
        )
    assert await run(maker, settings) == [Confirmation(GTIN, PRODUCT, 2)]
