"""Opted-in GTIN links as a count for the catalog (ADR 0014 section 3, owner decision D2).

Only ``{gtin, product_id, count}`` leaves the regional backend, as a *complete snapshot* in
pages, so an opt-out, a deletion or an erasure lowers a count at the next run without any
per-person signal. What is counted, and what never is:

* a **live medication** (not tombstoned) of a **live profile** (not tombstoned, not archived)
  whose link is opted in, with a consent record the server wrote (a supported version and a
  time; the version is write-only in the API, so it is read here from the database);
* by **distinct profile owners**: two managed profiles of one owner are one person;
* only profiles that are not **paused** (the owner or a guardian has a health-data consent, ADR
  0016 section 5): a paused profile's links are not counted, and come back at the next snapshot once
  it consents again;
* only accounts with a **verified** e-mail, **not pending deletion** (an own profile keeps its
  consent during the grace period, the count must not) and at least
  ``CATALOG_CONTRIBUTION_MIN_ACCOUNT_AGE_DAYS`` old (D8);
* only **shareable** GTINs (D3): a restricted number is never sent, whatever is stored;
* only counts of at least ``CATALOG_CONTRIBUTION_MIN_REPORTED_COUNT`` (2): one person's link
  never leaves the region.

Logs: the number of items and pages, never a GTIN or a product id.
"""

from __future__ import annotations

import asyncio
import uuid
from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any

from sqlalchemy import distinct, func, select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.catalog_client import CatalogIngestClient, CatalogUploadError
from app.config import Settings
from app.db.models import Medication, Profile, User
from app.domain.gtin import GtinError, normalize
from app.observability import get_logger
from app.services.consent_pause import profile_consented

_log = get_logger("pillpal.catalog_contributions")

MILLISECONDS = 1000
RATE_LIMITED = 429
DEFAULT_RETRY_AFTER_SECONDS = 1


@dataclass(frozen=True, slots=True)
class Confirmation:
    """The whole payload per link. No user, profile, medication or device id."""

    gtin: str
    product_id: uuid.UUID
    count: int


def _shareable_gtin14(raw: str) -> str | None:
    try:
        gtin = normalize(raw)
    except GtinError:
        return None
    return gtin.gtin14 if gtin.classification == "shareable" else None


async def aggregate_confirmations(
    maker: async_sessionmaker[AsyncSession], settings: Settings, now: datetime
) -> list[Confirmation]:
    """The counted links of this region, sorted by ``(gtin, product_id)``."""
    cutoff = now - timedelta(days=settings.catalog_contribution_min_account_age_days)
    owners = func.count(distinct(Profile.owner_user_id))
    statement = (
        select(Medication.gtin, Medication.catalog_product_id, owners)
        .join(Profile, Profile.id == Medication.profile_id)
        .join(User, User.id == Profile.owner_user_id)
        .where(
            Medication.gtin_link_shared.is_(True),
            Medication.deleted_at.is_(None),
            Medication.gtin.is_not(None),
            Medication.catalog_product_id.is_not(None),
            Medication.gtin_link_consented_at.is_not(None),
            Medication.gtin_link_consent_version.in_(settings.gtin_link_consent_versions),
            Profile.deleted_at.is_(None),
            Profile.archived_at.is_(None),
            User.email_verified_at.is_not(None),
            User.deletion_requested_at.is_(None),
            User.created_at <= cutoff,
            profile_consented(),
        )
        .group_by(Medication.gtin, Medication.catalog_product_id)
        .having(owners >= settings.catalog_contribution_min_reported_count)
    )
    async with maker() as session, session.begin():
        rows = (await session.execute(statement)).all()
    found: list[Confirmation] = []
    for gtin, product_id, count in rows:
        gtin14 = _shareable_gtin14(gtin) if gtin is not None else None
        if gtin14 is not None and product_id is not None:
            found.append(Confirmation(gtin14, product_id, int(count)))
    return sorted(found, key=lambda c: (c.gtin, str(c.product_id)))


def _pages(items: Sequence[Confirmation], size: int) -> list[Sequence[Confirmation]]:
    # An empty snapshot is still one page: it is how the catalog learns that counts went to zero.
    chunks = [items[i : i + size] for i in range(0, len(items), size)]
    return chunks or [items]


Sleep = Callable[[float], Awaitable[None]]


async def _put_page(
    client: CatalogIngestClient, settings: Settings, sleep: Sleep, **page: Any
) -> None:
    """One page; a 429 waits for Retry-After (capped) and resends the same page, a bounded
    number of times, instead of failing the whole run."""
    retries = settings.catalog_rate_limit_retries
    for attempt in range(retries + 1):
        try:
            await client.put_page(**page)
            return
        except CatalogUploadError as exc:
            if exc.status_code != RATE_LIMITED or attempt == retries:
                raise
            wait = exc.retry_after if exc.retry_after is not None else DEFAULT_RETRY_AFTER_SECONDS
            await sleep(min(wait, settings.catalog_rate_limit_max_sleep_seconds))


async def _send(
    client: CatalogIngestClient,
    settings: Settings,
    sleep: Sleep,
    items: Sequence[Confirmation],
    generation: int,
) -> int:
    pages = _pages(items, settings.catalog_contribution_page_size)
    for number, page in enumerate(pages):
        await _put_page(
            client,
            settings,
            sleep,
            generation=generation,
            page=number,
            complete=number == len(pages) - 1,
            items=page,
        )
    return len(pages)


async def push_gtin_confirmations(
    maker: async_sessionmaker[AsyncSession],
    settings: Settings,
    client: CatalogIngestClient,
    now: datetime,
    *,
    retract: bool = False,
    sleep: Sleep = asyncio.sleep,
) -> int:
    """Send one complete snapshot; returns the number of items. Raises on a failed page.

    ``retract`` sends the empty snapshot: the region counts at the catalog drop to zero at
    once (the feature was switched off, or the operator asked for it). A generation_stale
    answer (the catalog is ahead of this clock, or another run staged a newer generation) is
    retried once from the first page with a generation above the catalog hint.
    """
    items: list[Confirmation] = []
    if not retract:
        items = await aggregate_confirmations(maker, settings, now)
    generation = int(now.timestamp() * MILLISECONDS)
    try:
        pages = await _send(client, settings, sleep, items, generation)
    except CatalogUploadError as exc:
        if exc.code != "generation_stale" or exc.min_generation is None:
            raise
        _log.warning("catalog_generation_stale", hint_given=True)
        pages = await _send(client, settings, sleep, items, max(generation, exc.min_generation))
    _log.info("gtin_confirmations_pushed", items=len(items), pages=pages, retract=retract)
    return len(items)
