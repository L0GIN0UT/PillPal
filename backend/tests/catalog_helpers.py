"""Helpers of the catalog contribution suites (milestone 4.7): accounts that opted a link in."""

from __future__ import annotations

import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

from httpx import AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from tests.helpers import User, create_medication, register

GTIN = "04600000000015"
OTHER_GTIN = "04600000000022"
RESTRICTED_GTIN = "02000000000008"
PRODUCT = uuid.UUID("5b0f4a52-8e1b-4f60-9d3b-0a2f3c9d1e11")
OTHER_PRODUCT = uuid.UUID("5b0f4a52-8e1b-4f60-9d3b-0a2f3c9d1e22")
OLD_ENOUGH_DAYS = 30


async def age_account(engine: AsyncEngine, user: User, days: float) -> None:
    created = datetime.now(UTC) - timedelta(days=days)
    async with engine.begin() as conn:
        await conn.execute(
            text("UPDATE users SET created_at = :c WHERE id = :i"), {"c": created, "i": user.id}
        )


async def link(
    client: AsyncClient,
    user: User,
    *,
    gtin: str = GTIN,
    product: uuid.UUID = PRODUCT,
    shared: bool = True,
    profile_id: str | None = None,
) -> dict[str, Any]:
    """A medication linked to ``(gtin, product)``; opted in when ``shared`` (needs the
    ``contributions_on`` fixture)."""
    extra: dict[str, Any] = {}
    if shared:
        extra = {"gtin_link_shared": True, "gtin_link_consent_version": 1}
    if profile_id is not None:
        extra["profile_id"] = profile_id
    return await create_medication(
        client, user, gtin=gtin, catalog_product_id=str(product), **extra
    )


async def contributor(
    client: AsyncClient,
    engine: AsyncEngine,
    *,
    gtin: str = GTIN,
    product: uuid.UUID = PRODUCT,
    age_days: float = OLD_ENOUGH_DAYS,
) -> User:
    """A verified account old enough to count, with one opted-in link."""
    user = await register(client)
    await age_account(engine, user, age_days)
    await link(client, user, gtin=gtin, product=product)
    return user
