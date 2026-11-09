"""Fixtures of the consensus tests: empty catalog per test, candidate seeding, private app."""

from __future__ import annotations

import hashlib
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass

import pytest_asyncio
from httpx import ASGITransport, AsyncClient
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncEngine

from catalog.config import Settings
from catalog.domain.gtin import check_digit
from catalog.private_app import create_private_app
from tests.api.seed import Seed
from tests.conftest import make_settings
from tests.importers.support import wipe_catalog

# Children first: candidates, staging and decisions point at products.
CONSENSUS_TABLES = (
    "gtin_link_candidates",
    "gtin_candidate_staging",
    "gtin_ingest_state",
    "admin_audit",
    "gtin_link_decisions",
)

RU_SECRET = "ru-ingest-secret-" + "a" * 32
RU_NEXT_SECRET = "ru-ingest-next-" + "b" * 32
EU_SECRET = "eu-ingest-secret-" + "c" * 32
ADMIN_SECRET = "admin-secret-" + "d" * 32
ADMIN_SECOND_SECRET = "admin-second-" + "e" * 32


def digest(secret: str) -> str:
    return hashlib.sha256(secret.encode()).hexdigest()


def gtin14(body13: str) -> str:
    return body13 + check_digit(body13)


GTIN = gtin14("0460701234567")
OTHER_GTIN = gtin14("0460701234568")


def private_settings(**overrides: object) -> Settings:
    values: dict[str, object] = {
        "ingest_tokens": (
            f"ru:{digest(RU_SECRET)},ru-next:{digest(RU_NEXT_SECRET)},eu:{digest(EU_SECRET)}"
        ),
        "admin_tokens": f"ops:{digest(ADMIN_SECRET)},ops-next:{digest(ADMIN_SECOND_SECRET)}",
        "accepted_regions": "ru,eu",
    }
    values.update(overrides)
    return make_settings(**values)


async def wipe_consensus(engine: AsyncEngine) -> None:
    async with engine.begin() as conn:
        for table in CONSENSUS_TABLES:
            await conn.execute(text(f"DELETE FROM catalog.{table}"))  # noqa: S608
    await wipe_catalog(engine)


@dataclass
class Candidates:
    engine: AsyncEngine

    async def put(self, region: str, gtin: str, product: uuid.UUID, count: int) -> None:
        async with self.engine.begin() as conn:
            # A count only counts while its region's snapshot is fresh: record one as committed.
            await conn.execute(
                text(
                    "INSERT INTO catalog.gtin_ingest_state (region, committed_generation, "
                    "committed_at) VALUES (:r, 0, now()) ON CONFLICT (region) DO UPDATE "
                    "SET committed_at = now()"
                ),
                {"r": region},
            )
            await conn.execute(
                text(
                    "INSERT INTO catalog.gtin_link_candidates (region, gtin, product_id, "
                    "confirmations) VALUES (:r, :g, :p, :c) "
                    "ON CONFLICT (region, gtin, product_id) DO UPDATE SET confirmations = :c"
                ),
                {"r": region, "g": gtin, "p": product, "c": count},
            )

    async def clear(self) -> None:
        async with self.engine.begin() as conn:
            await conn.execute(text("DELETE FROM catalog.gtin_link_candidates"))

    async def rows(self, region: str | None = None) -> list[tuple[str, str, uuid.UUID, int]]:
        async with self.engine.connect() as conn:
            found = await conn.execute(
                text(
                    "SELECT region, gtin, product_id, confirmations FROM "
                    "catalog.gtin_link_candidates WHERE CAST(:r AS text) IS NULL OR region = :r "
                    "ORDER BY region, gtin, product_id"
                ),
                {"r": region},
            )
            return [(r.region, r.gtin, r.product_id, r.confirmations) for r in found]


@pytest_asyncio.fixture
async def seed(engine: AsyncEngine) -> AsyncIterator[Seed]:
    await wipe_consensus(engine)
    yield Seed(engine)
    await wipe_consensus(engine)


@pytest_asyncio.fixture
async def candidates(engine: AsyncEngine) -> Candidates:
    return Candidates(engine)


@asynccontextmanager
async def private_app_client(settings: Settings) -> AsyncIterator[AsyncClient]:
    """A client of the private app (admin and ingest) built on ``settings``."""
    app = create_private_app(settings)
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app, raise_app_exceptions=False)
        async with AsyncClient(transport=transport, base_url="http://private") as client:
            yield client


@pytest_asyncio.fixture
async def private_client(migrated_db: str, clean_redis: None) -> AsyncIterator[AsyncClient]:
    async with private_app_client(private_settings()) as client:
        yield client
